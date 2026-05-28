# openXTranscriber

A native macOS app that turns audio and video recordings into a clean, speaker-attributed transcript. Drop a file in, get back `<filename>_diarized.txt` with timestamped lines like:

```
[00:14] SPEAKER_00: Hi, thanks for joining today.
[00:18] Alex: Good to be here.
```

Multilingual transcription via [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) on Apple Silicon. Speaker diarization via [pyannote.audio](https://github.com/pyannote/pyannote-audio). Optional voice fingerprinting that learns recurring speakers from one meeting to the next, so `SPEAKER_03` becomes `Alex` automatically the second time you record him.

Sibling project to [openXRecorder](https://github.com/urglmorl/openXRecorder) — the recorder produces `.mov` files, this app turns them into transcripts.

## Features

- **Drag-and-drop** any audio or video file: `webm`, `mov`, `mp4`, `m4a`, `wav`, `mp3`, `ogg`, `flac`, `mkv`, `aac`.
- **Transcription** with mlx-whisper (Apple Silicon optimized). Models: `tiny`, `base`, `small`, `medium`, `large-v3-turbo`.
- **Speaker diarization** with pyannote/speaker-diarization-3.1.
- **Voice fingerprinting**: confirm a speaker's name once, and the app recognizes them in future recordings via cosine similarity over wespeaker embeddings.
- **Output** is a plain `.txt` file saved next to the source or in a fixed folder of your choice.
- **Localized UI** — English and Russian.
- **Multilingual transcription** — `ru`, `en`, `de`, `fr`, `es`, `it`.

## Requirements

- macOS 13 (Ventura) or later. Apple Silicon strongly recommended (mlx-whisper is MLX-only).
- Xcode 15 or later to build (tested with Xcode 26).
- A free [Hugging Face](https://huggingface.co/) account and access token. Pyannote's diarization models gate behind their license — you must accept the terms once on the model pages, then paste a token into the app.
- ~2 GB of disk for the managed Python runtime + downloaded models on first run.

If you only want transcription without speaker labels, the HF token and pyannote models are optional — the app will fall back to "transcription only" mode.

## Build and run

```bash
git clone git@github.com:urglmorl/openXTranscriber.git
cd openXTranscriber
open openXTranscriber.xcodeproj
```

Then ⌘R in Xcode.

## First-run setup (onboarding)

The first launch walks you through three steps:

1. **Sign in to Hugging Face** — open the link, create a free account.
2. **Accept model agreements** for these three models (one click each, "Access repository"):
   - `pyannote/speaker-diarization-3.1`
   - `pyannote/speaker-diarization-community-1`
   - `pyannote/segmentation-3.0`
3. **Create an access token** at huggingface.co/settings/tokens, paste it into the app, click **Verify Token and Finish**.

You can also click **Install Managed Runtime** during onboarding to pre-download the Python venv — otherwise it installs lazily on first transcription.

The token is stored in macOS Keychain. The runtime, models, and voice library live in `~/Library/Application Support/openXTranscriber/`.

## Usage

1. Drop a file onto the app, or click **Choose File**.
2. Click **Start Processing**. The app extracts audio, transcribes, diarizes, optionally matches voices.
3. When it finishes, the transcript path appears as a clickable link. **Open File** opens the `.txt` directly; clicking the path opens it in Finder.

If you have voice fingerprinting on and the app sees a speaker it's seen before, you'll be asked to confirm. Once confirmed, that voice is saved to `~/Library/Application Support/openXTranscriber/voices.json` and reused next time.

### Settings

Open with ⌘, or via the **Settings** button in the toolbar:

- **Language** — which language Whisper should expect.
- **Whisper model** — quality vs. speed trade-off. `large-v3-turbo` is the default and works well for all six languages.
- **Save mode** — next to the source file, or always in a fixed folder.
- **Voice Library** — toggle fingerprinting; tune the auto-label and suggest-only thresholds (cosine similarity).
- **Runtime** — point at a custom `python3` interpreter, or reinstall the managed venv.

## Output format

A plain text file `<source_name>_diarized.txt`. One line per turn:

```
[MM:SS] <SpeakerLabel>: <text>
```

Where `<SpeakerLabel>` is either `SPEAKER_00` / `SPEAKER_01` / ... (raw pyannote IDs) or a name from your voice library if confirmed.

If you ran in "transcription only" mode (no token, or the token didn't verify), every line uses a single placeholder speaker ID.

## Architecture

| File | Role |
|---|---|
| [`OpenXTranscriberApp.swift`](openXTranscriber/OpenXTranscriberApp.swift) | SwiftUI `@main`, file-open handling, scene setup |
| [`ContentView.swift`](openXTranscriber/ContentView.swift) | Main window: drop zone, runtime panel, processing UI, result view |
| [`OnboardingView.swift`](openXTranscriber/OnboardingView.swift) | First-run HF token + model-access flow |
| [`SettingsView.swift`](openXTranscriber/SettingsView.swift) | Preferences pane |
| [`SpeakerNamingSheet.swift`](openXTranscriber/SpeakerNamingSheet.swift) | Post-processing sheet for confirming/naming voices |
| [`VoiceLibraryView.swift`](openXTranscriber/VoiceLibraryView.swift) | Voice library section in Settings |
| [`TranscriberViewModel.swift`](openXTranscriber/TranscriberViewModel.swift) | Pipeline orchestration: extract → transcribe → diarize → embed → merge → save |
| [`Services.swift`](openXTranscriber/Services.swift) | Audio extraction (AVFoundation/ffmpeg fallback), Whisper/pyannote process wrappers, result formatter |
| [`RuntimeManager.swift`](openXTranscriber/RuntimeManager.swift) | Managed Python venv lifecycle in Application Support |
| [`ProcessRunner.swift`](openXTranscriber/ProcessRunner.swift) | Async wrapper around `Process` with line-buffered stdout/stderr |
| [`VoiceLibrary.swift`](openXTranscriber/VoiceLibrary.swift) | Cosine-similarity voice library backed by `voices.json` |
| [`KeychainHelper.swift`](openXTranscriber/KeychainHelper.swift) | HF token storage in macOS Keychain |
| [`Models.swift`](openXTranscriber/Models.swift) | Domain types: `ProcessingStage`, `DiarizedBlock`, `SpeakerMatch`, `PipelineError`, ... |
| [`Localizable.xcstrings`](openXTranscriber/Localizable.xcstrings) | String Catalog (English source + Russian) |
| [`Scripts/transcribe.py`](openXTranscriber/Scripts/transcribe.py) | mlx-whisper invocation, returns segments JSON |
| [`Scripts/diarize.py`](openXTranscriber/Scripts/diarize.py) | pyannote diarization, returns intervals JSON |
| [`Scripts/embed.py`](openXTranscriber/Scripts/embed.py) | Per-speaker voice embedding via wespeaker |

The pipeline is a chain of independent process invocations, each producing JSON on stdout. Swift orchestrates and merges. The Python scripts are bundled in the `.app` Resources, but at runtime they're staged into the managed runtime directory so the bundled venv can run them.

## Notes and limitations

- **Apple Silicon only** for transcription. mlx-whisper is built on MLX. The diarization and embedding scripts run on CPU by default; set `TRANSCRIBER_DIARIZATION_USE_MPS=1` / `TRANSCRIBER_EMBED_USE_MPS=1` in the runtime environment to try MPS — these fall back to CPU if any op isn't supported.
- **First run is slow.** The managed venv installs `mlx-whisper`, `pyannote.audio`, `torch`, and friends — multiple hundreds of MB of wheels plus the actual model weights on first transcription. Subsequent runs use the cache.
- **App sandbox is disabled** for personal-use simplicity. The managed runtime needs to write to Application Support and execute Python; sandboxing is solvable with the right entitlements but not currently set up.
- **Logs** for failed runs are written to `~/Library/Application Support/openXTranscriber/logs/`. Useful when something in the Python pipeline fails — the Swift error message is rarely the full picture.
- **Whisper hallucinations on silence** are mitigated via `hallucination_silence_threshold=2.0` in [`transcribe.py`](openXTranscriber/Scripts/transcribe.py). If you still see repeated phrases on noisy or low-volume audio, lowering this threshold (e.g. `1.5`) may help; raising it gives Whisper more rope on long pauses.

## Localization

UI strings live in [`Localizable.xcstrings`](openXTranscriber/Localizable.xcstrings). To add a language:

1. Open the catalog in Xcode.
2. Click **+** on the language list, pick the new locale.
3. Translate each entry, save.
4. Add the locale code to `knownRegions` in `project.pbxproj` (Xcode's UI does this for you).

Logs and developer-facing messages are intentionally English-only.

## Acknowledgements

- [OpenAI Whisper](https://github.com/openai/whisper) — the underlying transcription model.
- [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) — Apple Silicon port.
- [pyannote.audio](https://github.com/pyannote/pyannote-audio) — speaker diarization and voice embeddings.

## License

Licensed under the GNU Affero General Public License v3.0 — see [`LICENSE`](LICENSE) for the full text.

AGPL-3.0 is a strong copyleft license: if you modify this code and run your modified version as a network service, you must make your modified source available to the users of that service. For local use, build, and redistribution of source or binaries, the usual GPL terms apply.

Issues and pull requests welcome.
