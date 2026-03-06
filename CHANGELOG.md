# Changelog

## 0.1.4 (2026-03-05)

Removed incomplete benchmark suite from advanced settings.

### Improvements
- Removed incomplete benchmark suite from advanced settings to avoid confusion

---

## 0.1.3 (2026-03-03)

UI refinements, updated research citation, and website improvements.

### Improvements
- Updated research paper title across the app and documentation
- Behind the Research hero: refined title layout with improved spacing
- Settings reset button: solid dark red style for clear destructive intent
- Experimental pipeline tags: polished amber capsule pills for better visibility
- Website: improved mobile responsiveness and polished feature descriptions

---

## 0.1.2 (2026-03-03)

UI polish and website launch.

### Features
- API key setup help button with step-by-step instructions and cost estimate on the Configure Match screen
- Project website at foodmapper.app with light/dark theme, screenshot gallery, and mesh gradient background

### Fixes
- Inspector panel collapsing with no way to restore when dragged past minimum width
- Column and database picker dropdowns too narrow on macOS 26 Tahoe
- Tutorial step 10 wording: replaced jargon reference to "inspector" with clearer language

### Improvements
- Replace animated shine effect on Behind the Research card with refined static gradient glow
- Refine Settings > Advanced reset button: natural-width bordered button with destructive role instead of full-width red bar
- Fix Settings API Keys Save button using inconsistent button style in dark mode
- Replace filled SF Symbols in API key status badges with outlined variants
- Clarify Hybrid Matching info popover to explain both on and off states
- Add inline status label next to Hybrid Matching toggle showing current matching mode
- Improve info button visibility across Configure Match screen
- Show green checkmark with animated transition when API key is configured

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
