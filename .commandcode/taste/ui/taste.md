# UI taste

- Prefers purely informational/stable status to be rendered as plain text (e.g. a green "Connected" label), reserving interactive controls like buttons for states that actually offer an action (e.g. an orange "Connected" that triggers re-check/pairing). Confidence: 0.55
- When a state degrades feature availability, wants that explained in-place via a small info (info.circle) button + popover rather than leaving the limitation implicit. Confidence: 0.5
- Expects action controls to perform the real operation, not a passive/no-op re-read of cached state — e.g. a "check/connect" button should actively attempt the connection rather than merely re-reading an existing snapshot. Confidence: 0.45
