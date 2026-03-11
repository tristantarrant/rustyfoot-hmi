# Rustyfoot HMI

Flutter-based HMI (Human-Machine Interface) for MOD Audio's mod-ui system, designed for Raspberry Pi.

## Project Structure

```
lib/
├── main.dart                  # App entry point, navigation, drawer
├── hmi_server.dart            # TCP HMI server (mod-ui connects as client)
├── hmi_protocol.dart          # Protocol constants mirroring mod-ui's mod_protocol.py
├── pedalboards.dart           # Pedalboard list/switcher widget
├── pedalboard.dart            # Pedalboard model (parses TTL files)
├── pedal.dart                 # Pedal/plugin model, LV2PluginCache, FileParameter
├── pedal_editor.dart          # Parameter editor for pedals
├── file_types.dart            # File type configurations for user files
├── file_parameter_widget.dart # File parameter picker widget
├── bank.dart                  # Bank model (loads from banks.json)
├── banks.dart                 # Bank selection widget
├── tuner.dart                 # Chromatic tuner widget
├── snapshots.dart             # Snapshot management widget
├── transport.dart             # Tempo/transport control widget
├── bypass.dart                # Quick bypass and channel bypass widget
├── midi_settings.dart         # MIDI clock source/send settings widget
├── profiles.dart              # User profiles widget
├── qr.dart                    # Wi-Fi QR code widget
└── gpio_client.dart           # GPIO client for hardware buttons
```

## Architecture

### HMI Protocol
- Bidirectional TCP communication on port 9898
- Flutter app runs as **server**, mod-ui connects as **client**
- Commands are null-terminated strings (e.g., `pb 1 2\x00`)
- Protocol constants in `hmi_protocol.dart` mirror `mod-ui/mod/mod_protocol.py`

### Custom Protocol Extensions
- `cps` (CMD_CONTROL_PARAM_SET): Set plugin parameter values directly
  - Format: `cps <instance> <port_symbol> <value>`
  - Added to mod-ui in `mod/mod_protocol.py` and `mod/host.py`
- `fps` (CMD_FILE_PARAM_SET): Set plugin file parameter values
  - Format: `fps <instance> <param_uri> <file_path>`
  - For atom:Path parameters (samples, IRs, neural models)

### Data Paths
- `MOD_DATA_DIR` environment variable (fallback: `$HOME/data`)
- Pedalboards: `$MOD_DATA_DIR/pedalboards/`
- Banks: `$MOD_DATA_DIR/banks.json`
- LV2 plugins: `/usr/lib/lv2/`, `~/.lv2/`
- User files: `$MOD_USER_FILES_DIR` or `/data/user-files/`
  - Audio Samples, Speaker Cabinets IRs, Reverb IRs, SF2/SFZ Instruments, Aida DSP Models, NAM Models

## Key Classes

### HMIServer (hmi_server.dart)
Event streams:
- `onPedalboardChange` - pedalboard switch events (MIDI program change)
- `onPedalboardLoad` - pedalboard load events
- `onPedalboardClear` - pedalboard clear events (`pcl` command)
- `onFileParam` - file parameter value events (instance, paramUri, path)
- `onTuner` - tuner frequency/note/cents data
- `onSnapshots` - snapshot list updates
- `onMenuItem` - menu item value changes (tempo, bypass, MIDI settings)
- `onProfiles` - profile list updates

Outgoing commands:
- `loadPedalboard(index, {bankId})` - load pedalboard
- `setParameter(instance, portSymbol, value)` - set plugin control parameter
- `setFileParameter(instance, paramUri, path)` - set plugin file parameter
- `savePedalboard()` - save current pedalboard
- `tunerOn/Off()`, `setTunerInput()`, `setTunerRefFreq()`
- `loadSnapshot()`, `saveSnapshot()`, `saveSnapshotAs()`, `deleteSnapshot()`
- `setTempo()`, `setBeatsPerBar()`, `setPlayStatus()`
- `setQuickBypass()`, `setBypass1()`, `setBypass2()`
- `setMidiClockSource()`, `setMidiClockSend()`
- `loadProfile()`, `storeProfile()`

### LV2PluginCache (pedal.dart)
- Singleton that scans LV2 plugin directories
- Parses `manifest.ttl` and `modgui.ttl` for plugin metadata
- Caches `LV2PluginInfo` with control ports, file parameters, thumbnails, screenshots, etc.
- `modgui:screenshot` (245-452px) preferred over `modgui:thumbnail` (36-67px) for display
- File parameters: Parses `patch:writable` declarations with `rdfs:range atom:Path`
- Cache stored at `~/.cache/rustyfoot-hmi/lv2_cache.json` - must be cleared when adding new cached fields

### Pedalboard (pedalboard.dart)
- Parses pedalboard TTL files using rdflib
- `getPedals()` extracts plugin instances with current parameter values
- Sorting by path matches mod-ui's Lilv enumeration order

## Widget Index (drawer order)

| Index | Widget | Icon | Description |
|-------|--------|------|-------------|
| 0 | PedalboardsWidget | music_note | Pedalboard list/switcher |
| 1 | BanksWidget | folder | Bank selection |
| 2 | qrWidget | wifi | Wi-Fi QR code |
| 3 | TunerWidget | tune | Chromatic tuner |
| 4 | SnapshotsWidget | camera | Snapshot management |
| 5 | TransportWidget | speed | Tempo/transport control |
| 6 | BypassWidget | volume_off | Quick/channel bypass |
| 7 | MIDISettingsWidget | piano | MIDI clock settings |
| 8 | ProfilesWidget | person | User profiles |

## Dependencies

Key packages:
- `rdflib` - RDF/Turtle parsing for pedalboard/plugin TTL files
- `dart_periphery` - GPIO access for hardware buttons
- `ffi` - FFI for system calls (shutdown)
- `network_info_plus` - Network info for QR widget
- `qr_flutter` - QR code generation

### PedalboardsWidget (pedalboards.dart)
- Pedalboard switcher with PageView (swipe to change pedalboard)
- Edit mode: horizontal scrolling list of pedal cards with screenshots
- Pedal editor: opens PedalEditorWidget for parameter editing
- Listens to `onPedalboardLoad` and `onPedalboardClear` HMI events
- Parent (`main.dart`) listens to `onPedalboardChange`/`onPedalboardLoad` and passes `activePedalboardIndex` to switch view even when widget is not mounted
- File parameter values received from HMI are stored and applied when pedals load

## Related Project

mod-ui repository at `../mod-ui`:
- `mod/mod_protocol.py` - HMI protocol definitions
- `mod/host.py` - HMI command handlers
- `mod/hmi.py` - TcpHMI class with auto-reconnect support
- Custom `cps` command added for parameter setting
- Custom `fps` command added for file parameter setting
- Bypass state changes are sent via websockets (`msg_callback`), NOT via HMI TCP protocol

## Build & Run

```bash
flutter pub get
flutter run -d linux  # For desktop testing
flutter build linux   # For deployment
```

### Deployment to Raspberry Pi

The app runs on a Raspberry Pi named `tatooine` via `flutter-pi`:

```bash
flutterpi_tool run --release          # Build and deploy to Pi
ssh pi@tatooine "killall flutter-pi"  # Kill running instance (needed before redeploy if port 9898 conflict)
```

- Display: 800x480, 34px app bar, ~446px available body height
- `flutter-pi` device pixel ratio: 1.367054
- GPIO errors on startup are expected when running remotely (no GPIO access)
- Port 9898 "address already in use" error means previous instance still running - kill it first

### mod-ui Configuration (on Pi)

mod-ui runs as systemd service `mod-ui.service`. Config in `/home/pi/src/mod-ui/mod-ui.sh`:
- `MOD_HMI_TRANSPORT=tcp` (required, defaults to serial otherwise)
- `MOD_HMI_TCP_PORT=9898`

```bash
ssh pi@tatooine "sudo systemctl restart mod-ui"  # Restart mod-ui
ssh pi@tatooine "journalctl -u mod-ui -f"        # Check mod-ui logs
```

## Notes

- Pedalboards sorted by path to match Lilv enumeration order
- Parameter changes via `cps` are volatile (mark pedalboard modified but don't auto-save)
- Tuner auto-disables on widget dispose
- Some HMI features are firmware-level only (noise gate, compressor, system info)
- Clear plugin cache after updating: `ssh pi@tatooine "rm -f ~/.cache/rustyfoot-hmi/lv2_cache.json"`
- mod-ui auto-reconnects to rustyfoot-hmi when the TCP connection drops (via `set_close_callback` in `TcpHMI`)
- Handled HMI commands: `pb`, `pbl`, `pcl`, `is`, `boot`, `sn`, `r`, `mi`, `ts`, `pr`, `fn`, `tu`, `cps`, `fps`
- Tuner display uses `FittedBox(fit: BoxFit.scaleDown)` to prevent overflow on 480px height
