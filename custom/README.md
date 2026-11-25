# Mik's custom IINA settings

Personal settings for the IINA build of this `custom` branch. They are not
part of the app code: IINA reads them from the user's Library folder.

## Key bindings: `input_conf/INA Mik Custom.conf`

Copy of `~/Library/Application Support/com.colliderli.iina/input_conf/INA Mik Custom.conf`.

Differences from the IINA defaults worth knowing:

| Shortcut | Action |
| --- | --- |
| ⇧⌥D (`Alt+D`) | Delete current file (move to Trash) |
| ⌫ (`BS`) | Reset speed to 1.0 (replaces ⌘\\) |
| ⌥X / ⌥C / ⌥S | Clip: mark in / mark out / save (needs this branch's build) |
| ⇧⌥S (`Alt+S`) | Clip: save for sharing, as an MP4 Telegram plays, subtitles drawn on the video (needs this branch's build) |

In this format an uppercase letter means Shift: `Alt+D` is ⇧⌥D, `Meta+D` is ⌘⇧D.

### Install on a machine (instructions for an agent)

1. Quit IINA (`osascript -e 'quit app "IINA"'`): it rewrites its preferences on exit.
2. Copy the file, backing up any existing one with the same name:

   ```sh
   DIR="$HOME/Library/Application Support/com.colliderli.iina/input_conf"
   mkdir -p "$DIR"
   [ -f "$DIR/INA Mik Custom.conf" ] && cp "$DIR/INA Mik Custom.conf" "$DIR/INA Mik Custom.conf.bak"
   cp "custom/input_conf/INA Mik Custom.conf" "$DIR/"
   ```

3. Make it the active configuration (the name is the file name without `.conf`):

   ```sh
   defaults write com.colliderli.iina currentInputConfigName "INA Mik Custom"
   ```

4. Open IINA and check under Settings → Key Bindings that "INA Mik Custom" is selected,
   and that the File menu shows ⇧⌥D next to "Delete Current File".

### Update this copy

After changing shortcuts in IINA, copy the file back from the Library folder to
`custom/input_conf/` and commit it on the `custom` branch.
