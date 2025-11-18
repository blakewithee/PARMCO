# iPhone App - Automatic Mode Guide

## ✅ What Changed

The iPhone app now fully supports **Automatic Mode** with proper UI controls!

### UI Changes

**Replaced:** Button toggle  
**With:** Segmented Control `[Manual | Automatic]`

### Features Added

#### Manual Mode (Default) - **UNCHANGED!**
- ✅ All existing functionality works exactly as before
- ✅ Speed slider enabled (0-100%)
- ✅ Direction buttons work
- ✅ Start/Stop works
- ✅ RPM display works
- ✅ Sends same commands: `on`, `off`, `s N`, `f`, `r`

#### Automatic Mode (NEW!)
- 🎯 Speed slider **DISABLED** (grayed out, says "Speed (Auto-Controlled)")
- 🎯 Desired RPM field **VISIBLE**
- 🎯 Enter target RPM (0-3000)
- 🎯 Sends `"auto N"` command to Raspberry Pi
- 🎯 PID controller on Pi automatically maintains target RPM
- 🎯 Current RPM displayed on speedometer
- 🎯 Direction and Start/Stop still work

## How to Use

### Manual Mode (Same as Before!)
1. Launch app
2. Connect to "RaspberryPi"
3. **Mode is "Manual" by default**
4. Use speed slider to set speed (0-100%)
5. Press START
6. Motor runs at set speed
7. RPM displayed on speedometer

### Automatic Mode (NEW!)
1. Launch app
2. Connect to "RaspberryPi"
3. **Tap "Automatic" segment**
   - Speed slider becomes grayed out
   - "Desired RPM" field appears
4. **Enter target RPM** (e.g., 1000)
5. **Tap Done** on keyboard
   - App sends `"auto 1000"` command
6. Press START
7. **Motor automatically maintains 1000 RPM**
   - PID controller adjusts speed automatically
   - Speedometer shows current RPM
   - Speed slider is disabled (not used)

### Changing Target RPM (In Automatic Mode)
1. Enter new RPM value (e.g., 1500)
2. Tap Done
   - App sends `"auto 1500"`
   - Motor adjusts to new target

### Returning to Manual Mode
1. Tap "Manual" segment
   - App sends `"manual"` command
   - Speed slider becomes enabled
   - Desired RPM field hidden
2. Now you can use speed slider again

## Visual Indicators

### In Manual Mode:
```
Control Mode
[Manual] Automatic    ← Manual selected (orange)

Speed                 ← White text
[========>     ]      ← Enabled, full opacity
50%

(No Desired RPM field shown)
```

### In Automatic Mode:
```
Control Mode
Manual [Automatic]    ← Automatic selected (orange)

Speed (Auto-Controlled)   ← Gray text
[========>     ]          ← Disabled, 50% opacity, grayed out
48%

Desired RPM
[   1000    ]         ← Visible, enter target here
```

## Important Safety Notes

⚠️ **Start with Low RPM:** Begin with 500-800 RPM in automatic mode for testing  
⚠️ **Max RPM:** 3000 (hardcoded safety limit in both app and Pi)  
⚠️ **Direction:** You can change direction in automatic mode (motor will maintain RPM in new direction)  
⚠️ **Stop:** Press STOP button to turn off motor in either mode

## Behind the Scenes

### Commands Sent to Raspberry Pi:

**Manual Mode:**
- `on` - Start motor
- `off` - Stop motor
- `s 50` - Set speed to 50%
- `f` - Forward direction
- `r` - Reverse direction

**Automatic Mode:**
- `auto 1000` - Set target to 1000 RPM (enables automatic control)
- `auto 1500` - Change target to 1500 RPM
- `manual` - Return to manual mode
- `f`, `r`, `on`, `off` - Still work in automatic mode

### What Happens on the Pi:

**Manual Mode:**
- C program directly sets PWM duty cycle based on your speed slider
- No feedback control
- Speed stays constant unless you change it

**Automatic Mode:**
- C program runs PID controller every 100ms
- Reads current RPM from IR sensor
- Calculates error: `desired_rpm - current_rpm`
- Adjusts PWM duty cycle automatically to minimize error
- Motor maintains target RPM even if load changes

## Troubleshooting

### Speed slider doesn't gray out in automatic mode
- Make sure you tapped "Automatic" segment
- Check console logs for "Switching to AUTOMATIC mode"

### Desired RPM field doesn't appear
- Tap "Automatic" segment
- Field is hidden in manual mode by design

### Motor doesn't maintain RPM
- Check that Raspberry Pi received `"auto N"` command (check Pi terminal)
- Verify RPM sensor is working (check "Actual RPM" display)
- Try lower target RPM (500-800) for testing

### Can't adjust speed in automatic mode
- **This is correct!** Speed slider should be disabled
- In automatic mode, PID controller sets the speed
- If you want manual control, switch to "Manual" mode

### Switching modes doesn't work
- Check BLE connection is active
- Check Raspberry Pi terminal for received commands
- Try disconnecting and reconnecting

## Testing Checklist

- [ ] App starts in Manual mode
- [ ] Manual mode: speed slider works
- [ ] Manual mode: all buttons work (same as before)
- [ ] Switch to Automatic mode
- [ ] Automatic mode: speed slider grayed out
- [ ] Automatic mode: desired RPM field appears
- [ ] Enter RPM (e.g., 1000) and tap Done
- [ ] Start motor
- [ ] Motor maintains target RPM
- [ ] Change target RPM (e.g., 1500)
- [ ] Motor adjusts to new target
- [ ] Switch back to Manual mode
- [ ] Manual mode: speed slider works again

## Code Changes Summary

### MotorControlViewController.swift

**Changed:**
- `modeToggleButton` → `modeSegmentedControl` (better UX)

**Added:**
- `modeChanged()` - Handles mode switching
  - Sends `"auto N"` when entering automatic mode
  - Sends `"manual"` when returning to manual mode
  - Enables/disables speed slider
  - Shows/hides desired RPM field
  
- Updated `dismissKeyboard()` - Sends new target RPM when changed

**Unchanged:**
- All manual mode functionality
- All BLE communication
- RPM display
- Start/Stop, Direction buttons

---

**Enjoy your automatic RPM control!** 🎯

