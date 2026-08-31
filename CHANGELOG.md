# Changelog

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
