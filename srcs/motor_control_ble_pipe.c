/*
 * motor_control_ble_pipe.c
 * Motor control with RPM monitoring
 * Reads commands from keyboard AND named pipe (/tmp/motor_pipe)
 * The pipe is written to by ble_server.py (Python BLE server)
 * 
 * Compilation:
 * gcc -o motor_control_ble_pipe motor_control_ble_pipe.c -lpigpio -lrt -lpthread
 * 
 * Run:
 * 1. mkfifo /tmp/motor_pipe (one time only)
 * 2. sudo ./motor_control_ble_pipe
 * 3. In another terminal: sudo ./ble_server_c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/select.h>
#include <math.h>
#include <pigpio.h>
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>

// GPIO Pin Definitions
#define MOTOR_ENABLE_PIN 17
#define MOTOR_IN1_PIN    23
#define MOTOR_IN2_PIN    24
#define LED_PIN          25
#define IR_SENSOR_PIN    5

// Constants
#define PWM_FREQ_HZ 1000
#define NUM_BLADES 3
#define RPM_CALCULATION_WINDOW_MS 500  // Reduced from 1000ms for faster response
#define RPM_UPDATE_INTERVAL_MS 100
#define FIFO_PATH "/tmp/motor_pipe"
#define RPM_FIFO_PATH "/tmp/rpm_pipe"

// Global state
int g_speed = 0;
int g_motor_on = 0;
int g_direction = 1;
volatile int g_quit = 0;

// Control mode: 0 = manual, 1 = automatic
int g_control_mode = 0;  // Start in manual mode
double g_desired_rpm = 0.0;

// PID controller state for automatic mode
double g_pid_integral = 0.0;
double g_pid_last_error = 0.0;
uint32_t g_last_speed_change_time = 0;  // Track when we last changed speed

// PID tuning parameters - VERY GENTLE for smooth operation
#define KP 0.03   // Proportional gain (reduced from 0.15 - much gentler)
#define KI 0.005  // Integral gain (reduced from 0.02 - slower accumulation)
#define KD 0.01   // Derivative gain (reduced from 0.05 - less damping needed)
#define MAX_INTEGRAL 50.0   // Anti-windup limit (reduced from 100)
#define MAX_SPEED_CHANGE 2  // Max speed change per cycle (prevents spikes)
#define RPM_STABILIZE_DELAY_US 500000  // Wait 500ms after speed change for RPM to stabilize

// RPM state
volatile unsigned long g_pulse_count = 0;
volatile double g_current_rpm = 0.0;
pthread_t g_rpm_thread;
pthread_mutex_t g_rpm_mutex = PTHREAD_MUTEX_INITIALIZER;

// Pipe state
int g_pipe_fd = -1;
FILE* g_pipe_stream = NULL;

// RPM pipe state (for sending RPM to Python BLE server)
int g_rpm_pipe_fd = -1;
FILE* g_rpm_pipe_stream = NULL;

/**
 * =============================================================================
 * RPM MONITORING THREAD
 * =============================================================================
 * This thread runs continuously in the background to monitor the IR sensor
 * and calculate the motor's RPM (Revolutions Per Minute).
 * 
 * HOW IT WORKS:
 * 1. Reads the IR sensor pin to detect blade passes
 * 2. Records timestamps of each pulse (blade detection)
 * 3. Counts pulses within a time window (500ms by default)
 * 4. Calculates RPM: (pulses / num_blades) * (60 / window_seconds)
 * 5. Updates global g_current_rpm variable (thread-safe with mutex)
 * 6. Sends RPM updates to BLE server via named pipe for iPhone display
 * 
 * SENSOR SETUP:
 * - IR sensor outputs HIGH when blade is detected, LOW otherwise
 * - Each state change (edge) is counted as a pulse
 * - With 3 blades, we get 3 pulses per revolution
 * 
 * THREAD SAFETY:
 * - Uses pthread_mutex to protect g_current_rpm from race conditions
 * - Multiple threads read this value (main loop, PID controller)
 */
void* rpmThread(void* arg) {
    int last_state = -1;                // Previous sensor state (for edge detection)
    uint32_t pulse_times[1000];         // Circular buffer of pulse timestamps
    unsigned long pulse_count = 0;       // Total pulse count
    unsigned long pulse_index = 0;       // Current position in circular buffer
    
    // Initialize with current sensor state
    last_state = gpioRead(IR_SENSOR_PIN);
    
    while (!g_quit) {
        // Read current sensor state
        int current_state = gpioRead(IR_SENSOR_PIN);
        
        // EDGE DETECTION: Detect state change (blade passing sensor)
        if (last_state != -1 && last_state != current_state) {
            uint32_t current_time = gpioTick();  // Get microsecond timestamp
            g_pulse_count++;                      // Increment global counter
            
            // Store timestamp in circular buffer
            pulse_times[pulse_index] = current_time;
            pulse_index = (pulse_index + 1) % 1000;  // Wrap around at 1000
            if (pulse_count < 1000) {
                pulse_count++;  // Track how many pulses we have (up to 1000)
            }
        }
        
        last_state = current_state;  // Update for next iteration
        
        // RPM CALCULATION: Update every RPM_UPDATE_INTERVAL_MS (100ms)
        static uint32_t last_update = 0;
        uint32_t current_time = gpioTick();
        
        // Initialize on first run
        if (last_update == 0) {
            last_update = current_time;
        }
        
        // Calculate elapsed time, handling microsecond counter overflow (wraps at 32-bit max)
        uint32_t elapsed = current_time - last_update;
        if (current_time < last_update) {  // Overflow occurred
            elapsed = (0xFFFFFFFF - last_update) + current_time;
        }
        
        // Time to calculate RPM?
        if (elapsed >= (RPM_UPDATE_INTERVAL_MS * 1000)) {
            if (pulse_count > 0) {
                // COUNT PULSES IN TIME WINDOW
                // We only count pulses from the last RPM_CALCULATION_WINDOW_MS (500ms)
                // This gives us a more responsive RPM reading
                
                uint32_t window_ago = current_time - (RPM_CALCULATION_WINDOW_MS * 1000);
                uint32_t window_ago_adjusted = window_ago;
                if (current_time < window_ago) {  // Handle overflow
                    window_ago_adjusted = 0;
                }
                
                unsigned long pulses_in_window = 0;
                unsigned long count_to_check = (pulse_count < 1000) ? pulse_count : 1000;
                
                // Iterate through our circular buffer and count recent pulses
                for (unsigned long i = 0; i < count_to_check; i++) {
                    unsigned long idx = (pulse_index + 1000 - count_to_check + i) % 1000;
                    uint32_t pulse_time = pulse_times[idx];
                    
                    // Check if this pulse is within our time window
                    if (current_time >= pulse_time) {
                        uint32_t age = current_time - pulse_time;
                        if (age <= (RPM_CALCULATION_WINDOW_MS * 1000)) {
                            pulses_in_window++;
                        }
                    }
                }
                
                // CALCULATE RPM
                // Formula: RPM = (pulses / num_blades) * (60 seconds / window_seconds)
                // - Divide by NUM_BLADES because each revolution triggers NUM_BLADES pulses
                // - Multiply by 60 to convert revolutions/second to revolutions/minute
                pthread_mutex_lock(&g_rpm_mutex);  // Thread-safe update
                double window_seconds = RPM_CALCULATION_WINDOW_MS / 1000.0;
                g_current_rpm = (pulses_in_window / (double)NUM_BLADES) * (60.0 / window_seconds);
                pthread_mutex_unlock(&g_rpm_mutex);
            } else {
                // NO PULSES DETECTED - Motor stopped or sensor disconnected
                pthread_mutex_lock(&g_rpm_mutex);
                g_current_rpm = 0.0;
                pthread_mutex_unlock(&g_rpm_mutex);
            }
            
            last_update = current_time;  // Reset update timer
        }
        
        usleep(100);
    }
    
    return NULL;
}

/**
 * =============================================================================
 * PID CONTROLLER FOR AUTOMATIC MODE
 * =============================================================================
 * This implements a PID (Proportional-Integral-Derivative) controller to
 * automatically adjust motor speed to reach and maintain a desired RPM.
 * 
 * PID CONTROL THEORY:
 * - P (Proportional): Responds to current error (desired - actual)
 * - I (Integral): Eliminates steady-state error by accumulating past errors
 * - D (Derivative): Dampens oscillations by responding to rate of change
 * 
 * TUNING PARAMETERS (defined at top of file):
 * - KP = 0.03:  Gentle proportional response
 * - KI = 0.005: Slow integral accumulation
 * - KD = 0.01:  Minimal derivative damping
 * - MAX_INTEGRAL = 50.0: Prevents integral windup
 * - MAX_SPEED_CHANGE = 2: Limits speed change per cycle (prevents spikes)
 * - RPM_STABILIZE_DELAY_US = 500ms: Wait time after speed change
 * 
 * SPECIAL FEATURES:
 * 1. Stabilization Delay: Waits 500ms after each speed change to let RPM
 *    sensor catch up. Prevents oscillations from acting on stale RPM data.
 * 2. Anti-Windup: Only accumulates integral when error < 500 RPM
 * 3. Kickstart: Jumps to 20% minimum speed when starting from 0
 * 4. Rate Limiting: Max ±2% speed change per cycle for smooth operation
 * 
 * @param current_rpm: Measured RPM from sensor
 * @param desired_rpm: Target RPM from iPhone app
 * @return New motor speed (0-100%)
 */
int pidController(double current_rpm, double desired_rpm) {
    // SPECIAL CASE: Desired RPM is 0 → Turn off motor immediately
    if (desired_rpm < 1.0) {
        g_pid_integral = 0.0;           // Reset integral accumulator
        g_pid_last_error = 0.0;         // Reset derivative memory
        g_last_speed_change_time = 0;    // Reset stabilization timer
        return 0;
    }
    
    // STABILIZATION DELAY: Wait for RPM sensor to catch up after last speed change
    // This prevents oscillations from acting on stale RPM readings
    uint32_t current_time = gpioTick();
    if (g_last_speed_change_time > 0) {
        // Calculate how long since last speed change
        uint32_t elapsed = current_time - g_last_speed_change_time;
        if (current_time < g_last_speed_change_time) {  // Handle microsecond counter overflow
            elapsed = (0xFFFFFFFF - g_last_speed_change_time) + current_time;
        }
        
        // If not enough time has passed (< 500ms), don't adjust speed yet
        if (elapsed < RPM_STABILIZE_DELAY_US) {
            return g_speed;  // Keep current speed, wait for RPM to stabilize
        }
    }
    
    // CALCULATE ERROR: How far are we from target?
    double error = desired_rpm - current_rpm;
    
    // P-TERM (Proportional): Immediate response to error
    // Larger error → larger correction
    double p_term = KP * error;
    
    // I-TERM (Integral): Eliminate steady-state error
    // Accumulates error over time to push toward target
    // ANTI-WINDUP: Only accumulate when close to target (error < 500 RPM)
    if (fabs(error) < 500.0) {
        g_pid_integral += error;
        // Clamp integral to prevent windup (runaway accumulation)
        if (g_pid_integral > MAX_INTEGRAL) g_pid_integral = MAX_INTEGRAL;
        if (g_pid_integral < -MAX_INTEGRAL) g_pid_integral = -MAX_INTEGRAL;
    }
    double i_term = KI * g_pid_integral;
    
    // D-TERM (Derivative): Dampen oscillations
    // Responds to rate of change of error
    double d_term = KD * (error - g_pid_last_error);
    g_pid_last_error = error;  // Remember for next cycle
    
    // CALCULATE SPEED ADJUSTMENT
    int current_speed = g_speed;
    double adjustment = p_term + i_term + d_term;  // Combine all three terms
    
    // RATE LIMITING: Prevent sudden speed changes (max ±2% per cycle)
    // This is critical for smooth, stable operation
    if (adjustment > MAX_SPEED_CHANGE) adjustment = MAX_SPEED_CHANGE;
    if (adjustment < -MAX_SPEED_CHANGE) adjustment = -MAX_SPEED_CHANGE;
    
    int new_speed = current_speed + (int)adjustment;
    
    // CLAMP TO VALID RANGE (0-100%)
    if (new_speed < 0) new_speed = 0;
    if (new_speed > 100) new_speed = 100;
    
    // KICKSTART: Motor won't spin at very low speeds
    // If starting from 0, jump to 20% minimum
    if (current_speed == 0 && new_speed > 0 && new_speed < 20) {
        new_speed = 20;
    }
    
    // RECORD TIMESTAMP: If we changed speed, start stabilization delay timer
    if (new_speed != current_speed) {
        g_last_speed_change_time = gpioTick();
    }
    
    return new_speed;
}

/**
 * =============================================================================
 * MOTOR CONTROL FUNCTIONS
 * =============================================================================
 * These functions control the motor via an H-bridge driver using 3 GPIO pins:
 * - MOTOR_ENABLE_PIN (GPIO 17): PWM signal controls speed (0-100% duty cycle)
 * - MOTOR_IN1_PIN (GPIO 23): Direction control bit 1
 * - MOTOR_IN2_PIN (GPIO 24): Direction control bit 2
 * 
 * H-BRIDGE TRUTH TABLE:
 * IN1=HIGH, IN2=LOW  → Motor spins FORWARD (clockwise)
 * IN1=LOW,  IN2=HIGH → Motor spins REVERSE (counter-clockwise)
 * IN1=LOW,  IN2=LOW  → Motor BRAKE (both sides grounded)
 * IN1=HIGH, IN2=HIGH → Motor BRAKE (not used, avoid this state)
 * 
 * The ENABLE pin uses PWM (Pulse Width Modulation) to control speed:
 * - 0% duty cycle   → Motor off
 * - 50% duty cycle  → Half speed
 * - 100% duty cycle → Full speed
 */

/**
 * SET MOTOR DIRECTION
 * @param dir: 1 = forward (clockwise), 0 = reverse (counter-clockwise)
 */
void setDirection(int dir) {
    g_direction = dir;
    if (dir == 1) {
        // FORWARD: IN1=HIGH, IN2=LOW
        printf("-> Direction: FORWARD\n");
        gpioWrite(MOTOR_IN1_PIN, 1);
        gpioWrite(MOTOR_IN2_PIN, 0);
    } else {
        // REVERSE: IN1=LOW, IN2=HIGH
        printf("-> Direction: REVERSE\n");
        gpioWrite(MOTOR_IN1_PIN, 0);
        gpioWrite(MOTOR_IN2_PIN, 1);
    }
}

/**
 * SET MOTOR SPEED
 * Controls motor speed using PWM on the ENABLE pin.
 * 
 * PWM (Pulse Width Modulation) works by rapidly switching the motor power on/off:
 * - Higher duty cycle = more time ON = faster speed
 * - Lower duty cycle = less time ON = slower speed
 * - Frequency: 800 Hz (set in initialization)
 * 
 * @param speed: Desired speed (0-100%)
 *               0 = stopped, 100 = full speed
 */
void setSpeed(int speed) {
    // Clamp speed to valid range
    if (speed < 0) speed = 0;
    if (speed > 100) speed = 100;
    g_speed = speed;  // Update global state
    
    printf("-> Speed: %d%%\n", speed);
    
    if (speed == 0) {
        // Speed 0 = turn motor off completely
        g_motor_on = 0;
        gpioPWM(MOTOR_ENABLE_PIN, 0);  // Stop PWM
        gpioWrite(LED_PIN, 0);          // Turn off LED
    } else {
        // Speed > 0 = turn motor on and set PWM
        g_motor_on = 1;
        // Convert 0-100% to 0-255 PWM range (pigpio uses 0-255)
        int pwm_value = (speed * 255) / 100;
        gpioPWM(MOTOR_ENABLE_PIN, pwm_value);  // Apply PWM
        gpioWrite(LED_PIN, 1);                   // Turn on LED
    }
}

/**
 * TURN MOTOR ON
 * Enables the motor and applies the current speed setting.
 * If speed is 0, defaults to 50% to ensure motor spins.
 */
void motorOn() {
    // Check if already on
    if (g_motor_on) {
        printf("-> Motor already ON\n");
        return;
    }
    
    // Default to 50% speed if currently 0
    if (g_speed == 0) g_speed = 50;
    
    g_motor_on = 1;                  // Update global state
    setDirection(g_direction);       // Ensure direction is set
    setSpeed(g_speed);               // Apply speed (starts PWM and LED)
    printf("-> Motor ON\n");
}

/**
 * TURN MOTOR OFF
 * Stops the motor completely by:
 * 1. Setting PWM to 0 (no power)
 * 2. Setting both direction pins LOW (brake mode)
 * 3. Turning off status LED
 * 
 * This is a SAFE STOP - motor will not spin even if manually pushed.
 */
void motorOff() {
    printf("-> Motor OFF\n");
    g_motor_on = 0;                   // Update global state
    gpioPWM(MOTOR_ENABLE_PIN, 0);     // Stop PWM (no power)
    gpioWrite(MOTOR_IN1_PIN, 0);      // Set direction pins to brake mode
    gpioWrite(MOTOR_IN2_PIN, 0);      // (both LOW = brake)
    gpioWrite(LED_PIN, 0);             // Turn off status LED
}

/**
 * =============================================================================
 * NAMED PIPE (FIFO) MANAGEMENT
 * =============================================================================
 * Named pipes are used for inter-process communication (IPC):
 * - FIFO_PATH ("/tmp/motor_pipe"): BLE server → motor control (commands)
 * - RPM_FIFO_PATH ("/tmp/rpm_pipe"): motor control → BLE server (RPM data)
 * 
 * FIFO = First In, First Out
 * - One process writes, another reads
 * - Non-blocking mode: read returns immediately if no data
 * - Survives process restarts (exists in filesystem)
 */

/**
 * OPEN COMMAND PIPE FOR READING
 * Opens /tmp/motor_pipe to receive commands from BLE server.
 * Uses O_NONBLOCK so we don't block if BLE server isn't running yet.
 * 
 * ERROR HANDLING:
 * - ENXIO: No writer yet (BLE server not started) - this is normal
 * - Other errors: Real problems (permissions, file system issues)
 */
void openPipe() {
    // Try to open pipe in non-blocking mode
    g_pipe_fd = open(FIFO_PATH, O_RDONLY | O_NONBLOCK);
    
    if (g_pipe_fd == -1) {
        // ENXIO = no writer connected yet (normal condition)
        if (errno != ENXIO) {
            // Other errors could be problems (but don't exit - keep trying)
        }
        return;
    }
    
    // Wrap file descriptor in FILE* for easier reading
    g_pipe_stream = fdopen(g_pipe_fd, "r");
    if (g_pipe_stream == NULL) {
        // Failed to create stream - close FD and try again later
        close(g_pipe_fd);
        g_pipe_fd = -1;
        return;
    }
    
    printf("✓ BLE pipe connected! Ready for iPhone commands.\n");
}

/*
 * Close named pipe
 */
void closePipe() {
    if (g_pipe_stream) {
        fclose(g_pipe_stream);
        g_pipe_stream = NULL;
    }
    if (g_pipe_fd != -1) {
        close(g_pipe_fd);
        g_pipe_fd = -1;
    }
}

/*
 * Open RPM pipe for writing
 */
void openRPMPipe() {
    g_rpm_pipe_fd = open(RPM_FIFO_PATH, O_WRONLY | O_NONBLOCK);
    
    if (g_rpm_pipe_fd == -1) {
        if (errno != ENXIO) {
            // ENXIO means no reader yet (normal)
            // Other errors are real problems, but we'll try again later
        }
        return;
    }
    
    g_rpm_pipe_stream = fdopen(g_rpm_pipe_fd, "w");
    if (g_rpm_pipe_stream == NULL) {
        close(g_rpm_pipe_fd);
        g_rpm_pipe_fd = -1;
        return;
    }
    
    printf("✓ RPM pipe connected! Sending RPM updates to BLE server.\n");
}

/*
 * Close RPM pipe
 */
void closeRPMPipe() {
    if (g_rpm_pipe_stream) {
        fclose(g_rpm_pipe_stream);
        g_rpm_pipe_stream = NULL;
    }
    if (g_rpm_pipe_fd != -1) {
        close(g_rpm_pipe_fd);
        g_rpm_pipe_fd = -1;
    }
}

/**
 * SEND RPM TO BLE SERVER
 * Writes current RPM to named pipe so BLE server can send it to iPhone.
 * 
 * FORMAT: "rpm:####.##\n"
 * Example: "rpm:1234.56\n"
 * 
 * ERROR HANDLING:
 * If pipe write fails (BLE server disconnected), closes pipe and tries
 * to reopen on next call.
 * 
 * @param rpm: Current RPM value to send
 */
void sendRPM(double rpm) {
    if (g_rpm_pipe_stream) {
        char rpm_str[32];
        // Format: "rpm:####.##\n"
        snprintf(rpm_str, sizeof(rpm_str), "rpm:%.2f\n", rpm);
        
        // Try to write to pipe
        if (fputs(rpm_str, g_rpm_pipe_stream) >= 0) {
            fflush(g_rpm_pipe_stream);  // Ensure data is sent immediately
        } else {
            // Pipe broken (BLE server closed) - close and reopen later
            closeRPMPipe();
        }
    }
}

/**
 * =============================================================================
 * COMMAND PROCESSING
 * =============================================================================
 * Parses and executes commands from keyboard or BLE pipe.
 * 
 * COMMAND PROTOCOL:
 * Universal commands (work in both manual and automatic modes):
 *   - "on"   : Turn motor on
 *   - "off"  : Turn motor off
 *   - "f"    : Set direction forward (clockwise)
 *   - "r"    : Set direction reverse (counter-clockwise)
 *   - "rpm"  : Print current RPM
 *   - "q"    : Quit program
 * 
 * Manual mode commands:
 *   - "s N"  : Set speed to N% (0-100)
 *   - "+"    : Increase speed by 10%
 *   - "-"    : Decrease speed by 10%
 * 
 * Automatic mode commands:
 *   - "auto N" : Switch to automatic mode, target N RPM
 *   - "manual" : Switch back to manual mode
 * 
 * MODE BLOCKING:
 * In automatic mode, manual speed control commands (+, -, s) are blocked
 * to prevent interference with PID controller.
 */
void processCommand(char* input) {
    // Clean up input string - remove trailing newline/carriage return
    input[strcspn(input, "\n")] = 0;
    input[strcspn(input, "\r")] = 0;
    
    // Ignore empty commands
    if (strlen(input) == 0) return;
    
    printf("-> Command: [%s]\n", input);
    
    // AUTOMATIC MODE COMMAND: "auto N"
    // Switch to automatic mode with target RPM of N
    if (strncmp(input, "auto ", 5) == 0) {
        // Parse desired RPM from command
        double desired = atof(&input[5]);
        if (desired < 0) desired = 0;
        if (desired > 10000) desired = 10000;  // Safety limit: max 10,000 RPM
        
        g_desired_rpm = desired;
        g_control_mode = 1;  // Switch to automatic mode
        
        // Reset PID controller state (fresh start)
        g_pid_integral = 0.0;
        g_pid_last_error = 0.0;
        
        printf("-> AUTOMATIC MODE: Target RPM = %.2f\n", g_desired_rpm);
        
        // If desired RPM > 0, turn motor on
        if (g_desired_rpm > 0) {
            if (!g_motor_on) {
                g_motor_on = 1;
                setDirection(g_direction);
                if (g_speed == 0) g_speed = 30;  // Start at reasonable speed
                setSpeed(g_speed);
            }
        } else {
            // Desired RPM is 0 → turn motor off
            motorOff();
        }
        return;
    }
    
    // Check for manual mode command
    if (strcmp(input, "manual") == 0) {
        g_control_mode = 0;  // Switch to manual mode
        printf("-> MANUAL MODE\n");
        return;
    }
    
    // Commands that work in BOTH modes: on, off, f, r, rpm, q
    if (strcmp(input, "on") == 0) {
        motorOn();
        return;
    } else if (strcmp(input, "off") == 0) {
        motorOff();
        return;
    } else if (strcmp(input, "f") == 0) {
        setDirection(1);
        return;
    } else if (strcmp(input, "r") == 0) {
        setDirection(0);
        return;
    } else if (strcmp(input, "rpm") == 0) {
        pthread_mutex_lock(&g_rpm_mutex);
        double rpm = g_current_rpm;
        pthread_mutex_unlock(&g_rpm_mutex);
        printf("-> RPM: %.2f\n", rpm);
        return;
    } else if (strcmp(input, "q") == 0) {
        g_quit = 1;
        return;
    }
    
    // In automatic mode, reject manual speed control commands
    if (g_control_mode == 1) {
        printf("-> ERROR: In AUTOMATIC mode. Manual speed control disabled.\n");
        printf("   Use 'auto <rpm>' to change target, or 'manual' to switch modes.\n");
        return;
    }
    
    // Manual mode ONLY commands: speed control
    if (strcmp(input, "+") == 0) {
        setSpeed(g_speed + 10);
    } else if (strcmp(input, "-") == 0) {
        setSpeed(g_speed - 10);
    } else if (input[0] == 's' && input[1] == ' ') {
        int speed = atoi(&input[2]);
        setSpeed(speed);
    } else {
        printf("Unknown command: %s\n", input);
    }
}

void cleanup(int sig) {
    printf("\n🛑 Shutting down...\n");
    g_quit = 1;
    
    motorOff();
    closePipe();
    closeRPMPipe();
    
    if (g_rpm_thread) {
        pthread_join(g_rpm_thread, NULL);
    }
    
    gpioTerminate();
    exit(0);
}

int main() {
    printf("\n=== MOTOR CONTROL WITH BLE (via pipe) ===\n\n");
    
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);
    
    // Initialize GPIO
    if (gpioInitialise() < 0) {
        fprintf(stderr, "❌ Failed to initialize GPIO\n");
        return 1;
    }
    
    // Setup GPIO
    gpioSetMode(MOTOR_ENABLE_PIN, PI_OUTPUT);
    gpioSetMode(MOTOR_IN1_PIN, PI_OUTPUT);
    gpioSetMode(MOTOR_IN2_PIN, PI_OUTPUT);
    gpioSetMode(LED_PIN, PI_OUTPUT);
    gpioSetMode(IR_SENSOR_PIN, PI_INPUT);
    
    gpioSetPWMfrequency(MOTOR_ENABLE_PIN, PWM_FREQ_HZ);
    gpioSetPWMrange(MOTOR_ENABLE_PIN, 255);
    gpioSetPullUpDown(IR_SENSOR_PIN, PI_PUD_OFF);
    gpioGlitchFilter(IR_SENSOR_PIN, 0);
    
    motorOff();
    
    printf("✓ GPIO initialized\n");
    
    // Start RPM thread
    if (pthread_create(&g_rpm_thread, NULL, rpmThread, NULL) != 0) {
        fprintf(stderr, "❌ Failed to create RPM thread\n");
        gpioTerminate();
        return 1;
    }
    
    printf("✓ RPM monitoring started\n");
    
    // Create command pipe if it doesn't exist
    if (access(FIFO_PATH, F_OK) != 0) {
        if (mkfifo(FIFO_PATH, 0666) != 0) {
            perror("mkfifo");
            fprintf(stderr, "Failed to create pipe. Try: mkfifo %s\n", FIFO_PATH);
        } else {
            printf("✓ Created pipe: %s\n", FIFO_PATH);
        }
    }
    
    // Create RPM pipe if it doesn't exist
    if (access(RPM_FIFO_PATH, F_OK) != 0) {
        if (mkfifo(RPM_FIFO_PATH, 0666) != 0) {
            perror("mkfifo");
            fprintf(stderr, "Failed to create RPM pipe. Try: mkfifo %s\n", RPM_FIFO_PATH);
        } else {
            printf("✓ Created RPM pipe: %s\n", RPM_FIFO_PATH);
        }
    }
    
    printf("\n📱 Waiting for BLE server to connect...\n");
    printf("   Run: sudo python3 ble_server.py\n");
    printf("\n   === MANUAL MODE Commands ===\n");
    printf("   on, off     - Turn motor on/off\n");
    printf("   +, -        - Increase/decrease speed by 10%%\n");
    printf("   s N         - Set speed to N%% (0-100)\n");
    printf("   f, r        - Forward/Reverse direction\n");
    printf("   rpm         - Display current RPM\n");
    printf("\n   === AUTOMATIC MODE Commands ===\n");
    printf("   auto N      - Set target RPM and enable automatic control\n");
    printf("   manual      - Return to manual control mode\n");
    printf("\n   q           - Quit\n\n");
    
    // Main loop
    char input[256];
    int pipe_reconnect_timer = 0;
    
    while (!g_quit) {
        fd_set readfds;
        struct timeval timeout;
        int max_fd = STDIN_FILENO;
        
        FD_ZERO(&readfds);
        FD_SET(STDIN_FILENO, &readfds);
        
        if (g_pipe_fd != -1) {
            FD_SET(g_pipe_fd, &readfds);
            if (g_pipe_fd > max_fd) max_fd = g_pipe_fd;
        }
        
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;  // 100ms
        
        int ready = select(max_fd + 1, &readfds, NULL, NULL, &timeout);
        
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        
        // Check keyboard input
        if (ready > 0 && FD_ISSET(STDIN_FILENO, &readfds)) {
            if (fgets(input, sizeof(input), stdin) == NULL) break;
            processCommand(input);
        }
        
        // Check pipe input
        if (g_pipe_fd != -1 && ready > 0 && FD_ISSET(g_pipe_fd, &readfds)) {
            if (fgets(input, sizeof(input), g_pipe_stream) == NULL) {
                // Pipe closed - SAFETY: turn off motor!
                printf("⚠️  BLE server disconnected! TURNING MOTOR OFF FOR SAFETY!\n");
                motorOff();
                g_control_mode = 0;  // Return to manual mode
                closePipe();
                printf("   Waiting for reconnect...\n");
            } else {
                processCommand(input);
            }
        }
        
        // Try to reconnect pipe
        if (g_pipe_fd == -1) {
            pipe_reconnect_timer++;
            if (pipe_reconnect_timer >= 10) {  // Every 1 second
                pipe_reconnect_timer = 0;
                openPipe();
            }
        }
        
        // Display RPM and send to BLE server
        if (ready == 0) {
            pthread_mutex_lock(&g_rpm_mutex);
            double rpm = g_current_rpm;
            pthread_mutex_unlock(&g_rpm_mutex);
            
            // Run PID controller in automatic mode
            if (g_control_mode == 1 && g_motor_on) {
                int new_speed = pidController(rpm, g_desired_rpm);
                if (new_speed != g_speed) {
                    setSpeed(new_speed);
                }
            }
            
            // Send RPM to BLE server via pipe
            sendRPM(rpm);
            
            // Display status based on mode
            const char* mode_str = g_control_mode == 1 ? "AUTO" : "MANUAL";
            
            if (g_pipe_fd != -1) {
                if (g_control_mode == 1) {
                    printf("\r[BLE:%s] RPM: %7.2f/%7.2f | Motor: %s | Speed: %d%% | > ",
                           mode_str, rpm, g_desired_rpm, g_motor_on ? "ON" : "OFF", g_speed);
                } else {
                    printf("\r[BLE:%s] RPM: %7.2f | Motor: %s | Speed: %d%% | > ",
                           mode_str, rpm, g_motor_on ? "ON" : "OFF", g_speed);
                }
            } else {
                if (g_control_mode == 1) {
                    printf("\r[WAIT:%s] RPM: %7.2f/%7.2f | Motor: %s | Speed: %d%% | > ",
                           mode_str, rpm, g_desired_rpm, g_motor_on ? "ON" : "OFF", g_speed);
                } else {
                    printf("\r[WAIT:%s] RPM: %7.2f | Motor: %s | Speed: %d%% | > ",
                           mode_str, rpm, g_motor_on ? "ON" : "OFF", g_speed);
                }
            }
            fflush(stdout);
        }
        
        // Try to reconnect RPM pipe
        if (g_rpm_pipe_fd == -1) {
            static int rpm_reconnect_timer = 0;
            rpm_reconnect_timer++;
            if (rpm_reconnect_timer >= 10) {  // Every 1 second
                rpm_reconnect_timer = 0;
                openRPMPipe();
            }
        }
    }
    
    cleanup(0);
    return 0;
}

