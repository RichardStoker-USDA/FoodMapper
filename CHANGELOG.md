# Changelog

## 0.2.0 (2026-11-10)

More ways to load data, provider-assisted matching in Advanced mode, and a smaller experimental model set.

### Features
- Paste from Clipboard on the setup screen. Cells copied from a spreadsheet load as a table with the first row as the header, and plain text loads as one description per line
- Import a USDA FoodData Central CSV download (Foundation, SR Legacy, FNDDS, or Branded) as a target database, with each food's category and seven nutrients per 100 g. FoodMapper reads the folder you choose and downloads nothing
- Advanced mode: provider runs. GTE-Large retrieves candidates on the Mac, then an OpenAI model or a model on a local OpenAI-compatible server chooses among them. FoodMapper names what will be sent and asks before every run. A run accepts up to 10,000 rows
- Advanced mode: sign in with ChatGPT to run provider requests on a ChatGPT plan, or add an OpenAI API key. Sign-in tokens and keys are stored in the Keychain
- Advanced mode: target field settings for provider runs. Add a context phrase to the local search, send up to 8 target columns with each candidate, and apply a lowest or highest rule to a numeric column among candidates the provider lists as the same food. A row where the rule replaces the provider's pick goes to Needs Review
- Advanced mode: a 20-case retrieval benchmark records top-1, top-5, top-10, and latency for the installed model

### Fixes
- A description longer than 512 tokens is cut the way the published code cuts it, with the closing token kept. Descriptions that fit are unchanged. A custom database with descriptions long enough to be cut is embedded again the first time it is used

### Improvements
- Advanced mode now lists GTE-Large, the provider pipeline, and the cached-prompt Claude pipeline. The Qwen3 and Gemma experiments are removed, and FoodMapper deletes their downloads and cached embeddings from its own folders at launch. GTE-Large, databases, sessions, and input files are not touched
- Sessions recorded with a removed pipeline still open and keep their recorded method name
- "GTE-Large + Haiku v2" is renamed "GTE-Large + Claude (cached prompt)"
- Provider runs send several requests at once, retry temporary failures, and stop at a plan or quota limit with the remaining rows left in Needs Review
- Lower memory use during long runs on Macs with 64 GB or more
- Updated MLX-Swift to 0.33.0, swift-transformers to 1.4.0, and Sparkle to 2.10.1. The swift-transformers update brings in yyjson 0.13.0, which fixes a stack-buffer overflow (GHSA-f4vc-345x-4mvm)
- Status icons use outlined symbols, and the pipeline settings panels align

---

## 0.1.8 (2026-10-21)

Claude model availability and API key fixes.

### Fixes
- Saving an API key no longer rejects a valid key and removes it from the Keychain
- A key check that can't reach the provider keeps the saved key
- Hybrid matching stops before sending any data when the selected Claude model is retired
- A hybrid run where every Claude request fails reports the error instead of finishing with embedding-only results

### Improvements
- Claude 3 Haiku (`claude-3-haiku-20240307`), the model used in the paper, is marked retired as of April 20, 2026. FoodMapper keeps the identifier for provenance and does not substitute another model
- Claude model menus show retirement dates. Claude Sonnet 4.5 retires November 30, 2026
- Removed fixed API cost estimates

---

## 0.1.7 (2026-08-31)

macOS interface fixes.

### Fixes
- Appearance changes apply to the app and Settings window immediately
- Settings keeps the selected tab when its window gains focus
- Pipeline Configuration keeps model status text clear of the size selector
- The full Run Match capsule responds to clicks and stays accented when the window is inactive

### Improvements
- Restored the blue plus symbols for New Match and Custom Database
- Behind the Research uses one subtle icon cue per app session

---

## 0.1.6 (2026-08-31)

Manual Override, model setup, and data handling fixes.

### Fixes
- Manual Override now searches every row in the target database saved with a new session instead of only the retained candidates
- Manual selections retain the selected target ID and row fields in exports without assigning a similarity score
- Existing verified GTE-Large installations remain valid after model-card metadata changes
- CSV and TSV imports handle escaped quotes, quoted newlines, CRLF records, and duplicate headers; inconsistent row widths are rejected
- Interrupted custom-database and cache updates recover without replacing a valid stored database with partial files

### Improvements
- GTE-Large weights can download through four checked byte ranges when the server supports range requests
- Model download progress, cancellation, retry state, speed, and time estimates reset for each attempt
- Existing Anthropic API keys move from app preferences into the macOS Keychain after the Keychain write succeeds
- Advanced Help sections remain hidden until advanced options are enabled
- In-app publication links and research figures match the published paper

---

## 0.1.5 (2026-03-06)

Sonoma compatibility fixes for Research Showcase animations.

### Fixes
- Research Showcase animations not triggering on macOS Sonoma -- section reveals, counter animations, and pipeline pill sequences now fire correctly when scrolled into view
- Hero title animation on Sonoma -- replaced macOS 15+ text reveal renderer with unified fade+scale entrance that works across macOS 14-26

---

## 0.1.4 (2026-03-05)

Removed incomplete benchmark suite from advanced settings.

### Improvements
- Removed incomplete benchmark suite from advanced settings to avoid confusion

---

## 0.1.3 (2026-03-03)

Interface updates, corrected research citation, and website layout changes.

### Improvements
- Updated research paper title across the app and documentation
- Adjusted spacing in the Behind the Research title
- Settings reset button: solid dark red style for clear destructive intent
- Changed the experimental pipeline tags to muted amber capsule pills
- Fixed the website layout on small screens and revised feature descriptions

---

## 0.1.2 (2026-03-03)

Website launch and interface changes.

### Features
- API key setup help button with step-by-step instructions and cost estimate on the Configure Match screen
- Project website at foodmapper.app with light/dark theme and a screenshot gallery

### Fixes
- Inspector panel collapsing with no way to restore when dragged past minimum width
- Column and database picker dropdowns too narrow on macOS 26 Tahoe
- Tutorial step 10 wording: replaced jargon reference to "inspector" with clearer language

### Improvements
- Changed the Behind the Research card from an animated shine to a static gradient
- Changed the Settings > Advanced reset button to a bordered, natural-width destructive button
- Made the Settings API Keys Save button consistent in dark mode
- Replace filled SF Symbols in API key status badges with outlined variants
- Clarify Hybrid Matching info popover to explain both on and off states
- Add inline status label next to Hybrid Matching toggle showing current matching mode
- Improve info button visibility across Configure Match screen
- Show a green checkmark when the API key is configured

---

## 0.1.1 (2026-03-02)

First public release.

- On-device semantic matching using GTE-Large embeddings on Apple Silicon GPU
- Built-in reference databases: FooDB (9,913 items) and DFG2 (256 items)
- Custom database support with cached embeddings
- Optional hybrid pipeline with cloud LLM verification
- Guided review workflow with keyboard-driven decisions
- Session persistence with auto-save
- CSV and TSV import/export
- Interactive tutorial (19 steps)
