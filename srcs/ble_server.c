/*
 * BLE GATT Server in C - equivalent to ble_server.py
 * 
 * Bridges iPhone commands to C motor control program via named pipes.
 * Uses BlueZ D-Bus API (via GLib/GDBus).
 * 
 * Compile:
 *   gcc -o ble_server ble_server.c `pkg-config --cflags --libs glib-2.0 gio-2.0 gio-unix-2.0` -lpthread
 * 
 * Run:
 *   sudo ./ble_server
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <pthread.h>
#include <gio/gio.h>

// Configuration
#define FIFO_PATH "/tmp/motor_pipe"
#define RPM_FIFO_PATH "/tmp/rpm_pipe"

// Nordic UART Service UUIDs (matching iPhone app)
#define MOTOR_SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define COMMAND_CHAR_UUID  "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  // RX (write)
#define STATUS_CHAR_UUID   "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  // TX (notify)

// D-Bus paths and interfaces
#define BLUEZ_BUS_NAME "org.bluez"
#define GATT_MANAGER_IFACE "org.bluez.GattManager1"
#define LE_ADV_MANAGER_IFACE "org.bluez.LEAdvertisingManager1"
#define GATT_SERVICE_IFACE "org.bluez.GattService1"
#define GATT_CHRC_IFACE "org.bluez.GattCharacteristic1"
#define DEVICE_IFACE "org.bluez.Device1"

#define APP_PATH "/org/bluez/example"
#define SERVICE_PATH "/org/bluez/example/service0"
#define COMMAND_CHAR_PATH "/org/bluez/example/service0/char0"
#define STATUS_CHAR_PATH "/org/bluez/example/service0/char1"
#define ADV_PATH "/org/bluez/example/advertisement0"

// Global state
static GMainLoop *main_loop = NULL;
static GDBusConnection *dbus_conn = NULL;
static FILE *pipe_out = NULL;
static FILE *rpm_pipe_in = NULL;
static gboolean status_char_notifying = FALSE;
static gboolean last_connected_state = FALSE;
static guint rpm_timer_id = 0;

// Forward declarations
static void cleanup_and_exit(int code);
static void signal_handler(int signum);
static void register_app_callback(GDBusConnection *conn, GAsyncResult *res, gpointer user_data);
static void register_adv_callback(GDBusConnection *conn, GAsyncResult *res, gpointer user_data);
static void send_beeps(int count);

// ============================================================================
// PIPE MANAGEMENT
// ============================================================================

static gboolean open_command_pipe(void) {
    if (pipe_out) return TRUE;
    
    // Check if FIFO exists
    if (access(FIFO_PATH, F_OK) != 0) {
        printf("Creating named pipe: %s\n", FIFO_PATH);
        if (mkfifo(FIFO_PATH, 0666) < 0) {
            fprintf(stderr, "Failed to create pipe: %s\n", strerror(errno));
            return FALSE;
        }
    }
    
    printf("Opening command pipe '%s' for writing...\n", FIFO_PATH);
    printf("(This will block until C program opens it for reading)\n");
    
    pipe_out = fopen(FIFO_PATH, "w");
    if (!pipe_out) {
        fprintf(stderr, "Failed to open command pipe: %s\n", strerror(errno));
        fprintf(stderr, "Make sure C program is running: sudo ./motor_control_ble_pipe\n");
        return FALSE;
    }
    
    // Make pipe non-buffering for immediate writes
    setbuf(pipe_out, NULL);
    
    printf("✓ Command pipe opened! C program is reading from it.\n\n");
    return TRUE;
}

static void write_to_pipe(const char *command) {
    if (!pipe_out) {
        printf("[BLE] ERROR: Pipe not open\n");
        return;
    }
    
    if (fprintf(pipe_out, "%s", command) < 0) {
        printf("[BLE] ERROR: Failed to write to pipe: %s\n", strerror(errno));
        fclose(pipe_out);
        pipe_out = NULL;
        return;
    }
    
    fflush(pipe_out);
    printf("[BLE] Sent to C program: %s", command);
}

// ============================================================================
// BEEP FUNCTION (for connection feedback)
// ============================================================================

static void *beep_thread(void *arg) {
    int count = *(int *)arg;
    free(arg);
    
    if (!pipe_out) {
        printf("⚠️  Cannot beep: pipe not open\n");
        return NULL;
    }
    
    // Set speed to 50% so beeps are audible
    write_to_pipe("s 50\n");
    usleep(50000);  // 50ms
    
    for (int i = 0; i < count; i++) {
        write_to_pipe("on\n");
        usleep(150000);  // 150ms beep on
        write_to_pipe("off\n");
        if (i < count - 1) {
            usleep(100000);  // 100ms pause between beeps
        }
    }
    
    printf("✅ Beeped %d times\n", count);
    return NULL;
}

static void send_beeps(int count) {
    pthread_t tid;
    int *arg = malloc(sizeof(int));
    *arg = count;
    pthread_create(&tid, NULL, beep_thread, arg);
    pthread_detach(tid);
}

// ============================================================================
// RPM NOTIFICATION HANDLER
// ============================================================================
/**
 * READ RPM FROM PIPE AND SEND TO iPhone
 * This function is called periodically by GLib main loop (every 100ms).
 * It reads RPM data from the motor control program via named pipe and
 * sends it to the iPhone via BLE notifications.
 * 
 * PIPE FORMAT: "rpm:####.##\n"
 * Example: "rpm:1234.56\n"
 * 
 * BLE PROTOCOL:
 * - Reads from /tmp/rpm_pipe (motor control → BLE server)
 * - Sends via STATUS_CHAR_PATH (BLE → iPhone)
 * - Uses D-Bus PropertiesChanged signal for BLE notifications
 * 
 * FLOW:
 * 1. Check if iPhone has enabled notifications (status_char_notifying)
 * 2. Open RPM pipe if not already open
 * 3. Read RPM data using non-blocking select()
 * 4. Parse "rpm:####.##" format
 * 5. Send just the number (no "rpm:" prefix) to iPhone
 * 
 * @param user_data: Unused (required by GSourceFunc signature)
 * @return G_SOURCE_CONTINUE to keep timer running
 */
static gboolean read_rpm_from_pipe(gpointer user_data) {
    static char rpm_buffer[256];
    
    // Only send RPM if iPhone has enabled notifications
    if (!status_char_notifying) {
        return G_SOURCE_CONTINUE;  // Keep timer running
    }
    
    // OPEN RPM PIPE (if not already open)
    if (!rpm_pipe_in) {
        int fd = open(RPM_FIFO_PATH, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            if (errno != ENXIO) {  // ENXIO = no writer yet (normal)
                // CREATE PIPE: If it doesn't exist, create it once
                static gboolean pipe_created = FALSE;
                if (!pipe_created && errno == ENOENT) {
                    printf("Creating RPM pipe: %s\n", RPM_FIFO_PATH);
                    if (mkfifo(RPM_FIFO_PATH, 0666) == 0) {
                        pipe_created = TRUE;
                    }
                }
            }
            return G_SOURCE_CONTINUE;  // Try again next time
        }
        
        // Wrap file descriptor in FILE* for easier reading
        rpm_pipe_in = fdopen(fd, "r");
        if (!rpm_pipe_in) {
            close(fd);
            return G_SOURCE_CONTINUE;  // Try again next time
        }
        
        printf("[BLE] RPM pipe opened!\n");
    }
    
    // READ RPM DATA (non-blocking)
    // Use select() to check if data is available without blocking
    fd_set readfds;
    struct timeval tv = {0, 0};  // Non-blocking: return immediately
    FD_ZERO(&readfds);
    FD_SET(fileno(rpm_pipe_in), &readfds);
    
    // Check if data is available to read
    if (select(fileno(rpm_pipe_in) + 1, &readfds, NULL, NULL, &tv) > 0) {
        if (fgets(rpm_buffer, sizeof(rpm_buffer), rpm_pipe_in)) {
            // Remove newline character
            rpm_buffer[strcspn(rpm_buffer, "\n")] = 0;
            
            // PARSE RPM FORMAT: "rpm:####.##"
            if (strncmp(rpm_buffer, "rpm:", 4) == 0) {
                // Extract just the number (skip "rpm:" prefix)
                const char *rpm_value = rpm_buffer + 4;
                
                GError *error = NULL;
                GVariantBuilder builder;
                g_variant_builder_init(&builder, G_VARIANT_TYPE("ay"));
                
                // Convert string to byte array
                for (const char *p = rpm_value; *p; p++) {
                    g_variant_builder_add(&builder, "y", (guchar)*p);
                }
                g_variant_builder_add(&builder, "y", (guchar)'\n');
                
                GVariant *value = g_variant_builder_end(&builder);
                
                // Build the changed properties dictionary with the Value
                GVariantBuilder changed_props;
                g_variant_builder_init(&changed_props, G_VARIANT_TYPE("a{sv}"));
                g_variant_builder_add(&changed_props, "{sv}", "Value", value);
                
                // Build empty invalidated properties array
                GVariantBuilder invalidated;
                g_variant_builder_init(&invalidated, G_VARIANT_TYPE("as"));
                
                // Emit PropertiesChanged signal for notification
                g_dbus_connection_emit_signal(
                    dbus_conn,
                    NULL,  // destination (broadcast)
                    STATUS_CHAR_PATH,
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    g_variant_new("(sa{sv}as)",
                        GATT_CHRC_IFACE,
                        &changed_props,
                        &invalidated),
                    &error);
                
                if (error) {
                    // Don't print errors - RPM updates are too frequent
                    g_error_free(error);
                }
            }
        } else {
            // Read error - close and reopen
            if (ferror(rpm_pipe_in)) {
                fclose(rpm_pipe_in);
                rpm_pipe_in = NULL;
            }
        }
    }
    
    return G_SOURCE_CONTINUE;
}

// ============================================================================
// D-Bus METHOD HANDLERS
// ============================================================================
/**
 * HANDLE D-BUS METHOD CALLS FROM iPhone (via BlueZ)
 * This function is called whenever the iPhone sends a BLE request.
 * BlueZ translates BLE GATT operations into D-Bus method calls.
 * 
 * SUPPORTED METHODS:
 * 1. WriteValue (RX characteristic) - iPhone sends command
 * 2. ReadValue (any characteristic) - iPhone reads value
 * 3. StartNotify (TX characteristic) - iPhone enables notifications
 * 4. StopNotify (TX characteristic) - iPhone disables notifications
 * 
 * BLE → D-Bus MAPPING:
 * - BLE "Write" → D-Bus "WriteValue"
 * - BLE "Read" → D-Bus "ReadValue"
 * - BLE "Subscribe" → D-Bus "StartNotify"
 * - BLE "Unsubscribe" → D-Bus "StopNotify"
 * 
 * @param connection: D-Bus connection
 * @param sender: D-Bus sender (BlueZ)
 * @param object_path: D-Bus object path (characteristic path)
 * @param interface_name: D-Bus interface name
 * @param method_name: Method being called (WriteValue, ReadValue, etc.)
 * @param parameters: Method parameters
 * @param invocation: Method invocation context (for replying)
 * @param user_data: User data (unused)
 */
static void handle_method_call(
    GDBusConnection *connection,
    const gchar *sender,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *method_name,
    GVariant *parameters,
    GDBusMethodInvocation *invocation,
    gpointer user_data)
{
    // HANDLE WriteValue ON RX CHARACTERISTIC
    // This is called when iPhone sends a command (e.g., "on", "off", "s 50")
    if (g_strcmp0(object_path, COMMAND_CHAR_PATH) == 0 &&
        g_strcmp0(method_name, "WriteValue") == 0) {
        
        // Extract byte array from D-Bus parameters
        GVariant *value_variant = g_variant_get_child_value(parameters, 0);
        gsize len;
        gconstpointer data = g_variant_get_fixed_array(value_variant, &len, sizeof(guchar));
        
        // Convert byte array to null-terminated string
        char *command = g_malloc(len + 1);
        memcpy(command, data, len);
        command[len] = '\0';
        
        printf("[BLE] Received: %s", command);
        
        // Forward command to motor control program via named pipe
        write_to_pipe(command);
        
        // Clean up
        g_free(command);
        g_variant_unref(value_variant);
        
        // Reply to iPhone (success)
        g_dbus_method_invocation_return_value(invocation, NULL);
    }
    // HANDLE StartNotify ON TX CHARACTERISTIC
    // This is called when iPhone enables notifications for RPM updates
    else if (g_strcmp0(object_path, STATUS_CHAR_PATH) == 0 &&
             g_strcmp0(method_name, "StartNotify") == 0) {
        status_char_notifying = TRUE;  // Enable RPM notifications
        printf("[BLE] Notifications started for %s\n", STATUS_CHAR_UUID);
        g_dbus_method_invocation_return_value(invocation, NULL);
    }
    // HANDLE StopNotify ON TX CHARACTERISTIC
    // This is called when iPhone disables notifications
    else if (g_strcmp0(object_path, STATUS_CHAR_PATH) == 0 &&
             g_strcmp0(method_name, "StopNotify") == 0) {
        status_char_notifying = FALSE;  // Disable RPM notifications
        printf("[BLE] Notifications stopped\n");
        g_dbus_method_invocation_return_value(invocation, NULL);
    }
    // HANDLE ReadValue (for both characteristics)
    // This is called when iPhone reads a characteristic value
    else if (g_strcmp0(method_name, "ReadValue") == 0) {
        // Return empty byte array (we use notifications, not reads)
        GVariantBuilder builder;
        g_variant_builder_init(&builder, G_VARIANT_TYPE("ay"));
        g_dbus_method_invocation_return_value(invocation, 
            g_variant_new("(ay)", &builder));
    }
    // UNKNOWN METHOD
    else {
        g_dbus_method_invocation_return_error(invocation,
            G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
            "Method not implemented");
    }
}

static GVariant *handle_get_property(
    GDBusConnection *connection,
    const gchar *sender,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *property_name,
    GError **error,
    gpointer user_data)
{
    // Service properties
    if (g_strcmp0(object_path, SERVICE_PATH) == 0) {
        if (g_strcmp0(property_name, "UUID") == 0) {
            return g_variant_new_string(MOTOR_SERVICE_UUID);
        } else if (g_strcmp0(property_name, "Primary") == 0) {
            return g_variant_new_boolean(TRUE);
        } else if (g_strcmp0(property_name, "Characteristics") == 0) {
            GVariantBuilder builder;
            g_variant_builder_init(&builder, G_VARIANT_TYPE("ao"));
            g_variant_builder_add(&builder, "o", COMMAND_CHAR_PATH);
            g_variant_builder_add(&builder, "o", STATUS_CHAR_PATH);
            return g_variant_builder_end(&builder);
        }
    }
    // RX Characteristic properties
    else if (g_strcmp0(object_path, COMMAND_CHAR_PATH) == 0) {
        if (g_strcmp0(property_name, "UUID") == 0) {
            return g_variant_new_string(COMMAND_CHAR_UUID);
        } else if (g_strcmp0(property_name, "Service") == 0) {
            return g_variant_new_object_path(SERVICE_PATH);
        } else if (g_strcmp0(property_name, "Flags") == 0) {
            const gchar *flags[] = {"write-without-response", NULL};
            return g_variant_new_strv(flags, -1);
        } else if (g_strcmp0(property_name, "Notifying") == 0) {
            return g_variant_new_boolean(FALSE);
        } else if (g_strcmp0(property_name, "Value") == 0) {
            GVariantBuilder builder;
            g_variant_builder_init(&builder, G_VARIANT_TYPE("ay"));
            return g_variant_builder_end(&builder);
        }
    }
    // TX Characteristic properties
    else if (g_strcmp0(object_path, STATUS_CHAR_PATH) == 0) {
        if (g_strcmp0(property_name, "UUID") == 0) {
            return g_variant_new_string(STATUS_CHAR_UUID);
        } else if (g_strcmp0(property_name, "Service") == 0) {
            return g_variant_new_object_path(SERVICE_PATH);
        } else if (g_strcmp0(property_name, "Flags") == 0) {
            const gchar *flags[] = {"notify", NULL};
            return g_variant_new_strv(flags, -1);
        } else if (g_strcmp0(property_name, "Notifying") == 0) {
            return g_variant_new_boolean(status_char_notifying);
        } else if (g_strcmp0(property_name, "Value") == 0) {
            GVariantBuilder builder;
            g_variant_builder_init(&builder, G_VARIANT_TYPE("ay"));
            return g_variant_builder_end(&builder);
        }
    }
    
    return NULL;
}

// ============================================================================
// REGISTRATION CALLBACK (like Python's reply_handler/error_handler)
// ============================================================================

static void register_app_callback(GDBusConnection *conn, GAsyncResult *res, gpointer user_data) {
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_finish(conn, res, &error);
    
    if (error) {
        fprintf(stderr, "\n❌ Failed to register GATT application: %s\n", error->message);
        fprintf(stderr, "Make sure Bluetooth is enabled!\n\n");
        fprintf(stderr, "Try running: sudo ./setup_bluetooth.sh\n");
        g_error_free(error);
        cleanup_and_exit(1);
        return;
    }
    
    if (result) {
        g_variant_unref(result);
    }
    
    printf("✅ GATT application registered successfully!\n");
    printf("   Service UUID: %s\n", MOTOR_SERVICE_UUID);
    printf("   RX UUID: %s (commands)\n", COMMAND_CHAR_UUID);
    printf("   TX UUID: %s (RPM notifications)\n", STATUS_CHAR_UUID);
    printf("\n   Commands:\n");
    printf("   - Manual: on, off, s N, +, -, f, r\n");
    printf("   - Auto: auto N (target RPM), manual (exit auto mode)\n");
    
    // Now register BLE advertising so iPhone can discover us
    printf("\nRegistering BLE advertisement...\n");
    
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&builder, "{sv}", "Type", g_variant_new_string("peripheral"));
    
    // Add service UUIDs to advertise
    GVariantBuilder uuid_builder;
    g_variant_builder_init(&uuid_builder, G_VARIANT_TYPE("as"));
    g_variant_builder_add(&uuid_builder, "s", MOTOR_SERVICE_UUID);
    g_variant_builder_add(&builder, "{sv}", "ServiceUUIDs", g_variant_builder_end(&uuid_builder));
    
    // Add local name
    g_variant_builder_add(&builder, "{sv}", "LocalName", g_variant_new_string("RaspberryPi"));
    
    GVariant *adv_params = g_variant_builder_end(&builder);
    
    g_dbus_connection_call(
        dbus_conn,
        BLUEZ_BUS_NAME,
        "/org/bluez/hci0",
        LE_ADV_MANAGER_IFACE,
        "RegisterAdvertisement",
        g_variant_new("(o@a{sv})", "/org/bluez/example/advertisement0", adv_params),
        NULL,
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        NULL,
        (GAsyncReadyCallback)register_adv_callback,
        NULL);
}

static void register_adv_callback(GDBusConnection *conn, GAsyncResult *res, gpointer user_data) {
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_finish(conn, res, &error);
    
    if (error) {
        fprintf(stderr, "⚠️  Failed to register advertisement: %s\n", error->message);
        fprintf(stderr, "   iPhone may not be able to discover this device\n");
        fprintf(stderr, "   But BLE server will still work if you know the address\n");
        g_error_free(error);
    } else {
        if (result) {
            g_variant_unref(result);
        }
        printf("✅ Advertisement registered!\n");
        printf("   Device name: RaspberryPi\n");
        printf("   Service UUID: %s\n", MOTOR_SERVICE_UUID);
    }
    
    printf("\n📱 Waiting for iPhone to connect...\n");
    printf("   Connect from iPhone app and send commands!\n");
    printf("   RPM updates will be sent automatically when connected.\n");
    printf("   Press Ctrl+C to stop\n\n");
}

// ============================================================================
// CONNECTION MONITOR
// ============================================================================

static void on_properties_changed(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data)
{
    // Only handle Device1 interface
    const char *iface;
    g_variant_get_child(parameters, 0, "&s", &iface);
    if (g_strcmp0(iface, DEVICE_IFACE) != 0) {
        return;
    }
    
    // Check for Connected property
    GVariant *changed_props = g_variant_get_child_value(parameters, 1);
    GVariant *connected_variant = g_variant_lookup_value(changed_props, "Connected", G_VARIANT_TYPE_BOOLEAN);
    
    if (connected_variant) {
        gboolean connected = g_variant_get_boolean(connected_variant);
        
        // Only trigger if state actually changed
        if (connected != last_connected_state) {
            last_connected_state = connected;
            
            if (connected) {
                printf("📱 Device connected! Beeping 4 times...\n");
                send_beeps(4);
            } else {
                printf("📴 Device disconnected! TURNING MOTOR OFF FOR SAFETY!\n");
                write_to_pipe("off\n");
                printf("   ✅ Sent OFF command to motor\n");
                send_beeps(4);
            }
        }
        
        g_variant_unref(connected_variant);
    }
    
    g_variant_unref(changed_props);
}

// ============================================================================
// D-Bus OBJECT MANAGER
// ============================================================================

static void handle_get_managed_objects(
    GDBusConnection *connection,
    const gchar *sender,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *method_name,
    GVariant *parameters,
    GDBusMethodInvocation *invocation,
    gpointer user_data)
{
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{oa{sa{sv}}}"));
    
    // Add service
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{oa{sa{sv}}}"));
    g_variant_builder_add(&builder, "o", SERVICE_PATH);
    
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sa{sv}}"));
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{sa{sv}}"));
    g_variant_builder_add(&builder, "s", GATT_SERVICE_IFACE);
    
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&builder, "{sv}", "UUID", g_variant_new_string(MOTOR_SERVICE_UUID));
    g_variant_builder_add(&builder, "{sv}", "Primary", g_variant_new_boolean(TRUE));
    
    GVariantBuilder char_builder;
    g_variant_builder_init(&char_builder, G_VARIANT_TYPE("ao"));
    g_variant_builder_add(&char_builder, "o", COMMAND_CHAR_PATH);
    g_variant_builder_add(&char_builder, "o", STATUS_CHAR_PATH);
    g_variant_builder_add(&builder, "{sv}", "Characteristics", g_variant_builder_end(&char_builder));
    
    g_variant_builder_close(&builder);  // a{sv}
    g_variant_builder_close(&builder);  // {sa{sv}}
    g_variant_builder_close(&builder);  // a{sa{sv}}
    g_variant_builder_close(&builder);  // {oa{sa{sv}}}
    
    // Add RX characteristic
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{oa{sa{sv}}}"));
    g_variant_builder_add(&builder, "o", COMMAND_CHAR_PATH);
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sa{sv}}"));
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{sa{sv}}"));
    g_variant_builder_add(&builder, "s", GATT_CHRC_IFACE);
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&builder, "{sv}", "UUID", g_variant_new_string(COMMAND_CHAR_UUID));
    g_variant_builder_add(&builder, "{sv}", "Service", g_variant_new_object_path(SERVICE_PATH));
    const gchar *rx_flags[] = {"write-without-response", NULL};
    g_variant_builder_add(&builder, "{sv}", "Flags", g_variant_new_strv(rx_flags, -1));
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    
    // Add TX characteristic
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{oa{sa{sv}}}"));
    g_variant_builder_add(&builder, "o", STATUS_CHAR_PATH);
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sa{sv}}"));
    g_variant_builder_open(&builder, G_VARIANT_TYPE("{sa{sv}}"));
    g_variant_builder_add(&builder, "s", GATT_CHRC_IFACE);
    g_variant_builder_open(&builder, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&builder, "{sv}", "UUID", g_variant_new_string(STATUS_CHAR_UUID));
    g_variant_builder_add(&builder, "{sv}", "Service", g_variant_new_object_path(SERVICE_PATH));
    const gchar *tx_flags[] = {"notify", NULL};
    g_variant_builder_add(&builder, "{sv}", "Flags", g_variant_new_strv(tx_flags, -1));
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    g_variant_builder_close(&builder);
    
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(a{oa{sa{sv}}})", &builder));
}

// ============================================================================
// MAIN SETUP
// ============================================================================

static const GDBusInterfaceVTable service_vtable = {
    handle_method_call,
    handle_get_property,
    NULL  // set_property
};

static const GDBusInterfaceVTable om_vtable = {
    handle_get_managed_objects,
    NULL,
    NULL
};

static void cleanup_and_exit(int code) {
    printf("\n[BLE] Stopping server...\n");
    
    // SAFETY: Turn off motor
    printf("[BLE] SAFETY: Turning motor off...\n");
    if (pipe_out) {
        write_to_pipe("off\n");
        printf("   ✅ Motor OFF command sent\n");
        fclose(pipe_out);
        pipe_out = NULL;
    }
    
    if (rpm_pipe_in) {
        fclose(rpm_pipe_in);
        rpm_pipe_in = NULL;
    }
    
    if (rpm_timer_id) {
        g_source_remove(rpm_timer_id);
    }
    
    if (main_loop) {
        g_main_loop_quit(main_loop);
    }
    
    printf("[BLE] Server shut down\n");
    exit(code);
}

static void signal_handler(int signum) {
    cleanup_and_exit(0);
}

int main(int argc, char *argv[]) {
    GError *error = NULL;
    
    printf("\n=== BLE Server (C) ===\n\n");
    
    // Install signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Open command pipe
    if (!open_command_pipe()) {
        return 1;
    }
    
    // Connect to system D-Bus
    dbus_conn = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (error) {
        fprintf(stderr, "Failed to connect to D-Bus: %s\n", error->message);
        g_error_free(error);
        return 1;
    }
    
    // Subscribe to device connection events
    g_dbus_connection_signal_subscribe(
        dbus_conn,
        BLUEZ_BUS_NAME,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        NULL,  // object path (any)
        NULL,  // arg0 (any)
        G_DBUS_SIGNAL_FLAGS_NONE,
        on_properties_changed,
        NULL,
        NULL);
    
    printf("✓ Subscribed to device connection events\n");
    
    // Register object manager interface (required for GATT)
    static const gchar om_introspection[] =
        "<node>"
        "  <interface name='org.freedesktop.DBus.ObjectManager'>"
        "    <method name='GetManagedObjects'>"
        "      <arg type='a{oa{sa{sv}}}' name='objects' direction='out'/>"
        "    </method>"
        "  </interface>"
        "</node>";
    
    GDBusNodeInfo *om_info = g_dbus_node_info_new_for_xml(om_introspection, &error);
    if (error) {
        fprintf(stderr, "Failed to parse ObjectManager interface: %s\n", error->message);
        g_error_free(error);
        return 1;
    }
    
    g_dbus_connection_register_object(
        dbus_conn,
        APP_PATH,
        om_info->interfaces[0],
        &om_vtable,
        NULL, NULL, &error);
    
    if (error) {
        fprintf(stderr, "Failed to register ObjectManager: %s\n", error->message);
        g_error_free(error);
        return 1;
    }
    
    g_dbus_node_info_unref(om_info);
    
    // Register GATT service and characteristics
    static const gchar service_introspection[] =
        "<node>"
        "  <interface name='org.bluez.GattService1'>"
        "    <property name='UUID' type='s' access='read'/>"
        "    <property name='Primary' type='b' access='read'/>"
        "    <property name='Characteristics' type='ao' access='read'/>"
        "  </interface>"
        "</node>";
    
    GDBusNodeInfo *service_info = g_dbus_node_info_new_for_xml(service_introspection, &error);
    g_dbus_connection_register_object(dbus_conn, SERVICE_PATH, service_info->interfaces[0],
        &service_vtable, NULL, NULL, &error);
    g_dbus_node_info_unref(service_info);
    
    static const gchar char_introspection[] =
        "<node>"
        "  <interface name='org.bluez.GattCharacteristic1'>"
        "    <property name='UUID' type='s' access='read'/>"
        "    <property name='Service' type='o' access='read'/>"
        "    <property name='Flags' type='as' access='read'/>"
        "    <property name='Notifying' type='b' access='read'/>"
        "    <property name='Value' type='ay' access='read'/>"
        "    <method name='ReadValue'>"
        "      <arg name='options' type='a{sv}' direction='in'/>"
        "      <arg name='value' type='ay' direction='out'/>"
        "    </method>"
        "    <method name='WriteValue'>"
        "      <arg name='value' type='ay' direction='in'/>"
        "      <arg name='options' type='a{sv}' direction='in'/>"
        "    </method>"
        "    <method name='StartNotify'/>"
        "    <method name='StopNotify'/>"
        "  </interface>"
        "</node>";
    
    GDBusNodeInfo *char_info = g_dbus_node_info_new_for_xml(char_introspection, &error);
    g_dbus_connection_register_object(dbus_conn, COMMAND_CHAR_PATH, char_info->interfaces[0],
        &service_vtable, NULL, NULL, &error);
    g_dbus_connection_register_object(dbus_conn, STATUS_CHAR_PATH, char_info->interfaces[0],
        &service_vtable, NULL, NULL, &error);
    g_dbus_node_info_unref(char_info);
    
    // Create main loop before registration (important!)
    main_loop = g_main_loop_new(NULL, FALSE);
    
    // Find adapter and register GATT application (ASYNC like Python)
    printf("Registering GATT application...\n");
    
    // Use ASYNC call with callback (like Python does)
    g_dbus_connection_call(
        dbus_conn,
        BLUEZ_BUS_NAME,
        "/org/bluez/hci0",
        GATT_MANAGER_IFACE,
        "RegisterApplication",
        g_variant_new("(oa{sv})", APP_PATH, NULL),
        NULL,
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        NULL,
        (GAsyncReadyCallback)register_app_callback,
        NULL);
    
    // Let the async call process - callback will be called when done
    // (This is the key difference from sync call - we don't block)
    
    // Start RPM reading timer (100ms interval)
    rpm_timer_id = g_timeout_add(100, read_rpm_from_pipe, NULL);
    
    // Run main loop - this processes the async registration
    printf("Starting event loop...\n");
    g_main_loop_run(main_loop);
    
    cleanup_and_exit(0);
    return 0;
}

