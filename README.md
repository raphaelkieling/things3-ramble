# Things 3 Ramble

A macOS menu bar app that transcribes your speech with OpenAI and previews tasks before sending them to Things 3.


<div align="center">
  <img width="512" height="252" alt="image" src="https://github.com/user-attachments/assets/0562e036-1fd2-4234-9878-19fd80b30043" />
</div>


## Build and run

Requires macOS 14+ and the Xcode Command Line Tools with Swift 6+.

```sh
./build.sh && open "dist/Things 3 Ramble.app"
```

Open **Ajustes…** (Settings) from the Ramble menu and save your OpenAI API key and Things 3 URL token. In Things, find the token under **Settings → General → Enable Things URLs → Manage**.

Press **⌘⇧.** and grant microphone access on your first capture. Say your tasks, review the preview, then press **Enter** to send or **Esc** to cancel.

## Test

```sh
./test.sh          # Automated tests
./build.sh --demo  # Demo with sample data, no credentials or microphone needed
```
