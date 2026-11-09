# Source detail and protected artwork

Colorization runs through the local FLUX.2 Klein workflow described in the root [README](../README.md). Input images are prepared for model inference; if inference uses fewer pixels than the original, the final PNG is resized back to the original dimensions. Resizing restores the canvas dimensions but cannot recover detail the model did not produce.

Optional source restoration uses user-selected masks/regions to copy approved pixels from the source after colorization. These masks should protect text, bubbles, panel borders, and other regions only when their alignment with the generated image has been checked. Do not use a full-page protection mask when you expect that page to be colorized.

The model can change lettering, eyes, small shapes, and object geometry. Ink restoration preserves some source line detail but is not semantic reconstruction. Compare original, raw model output, and final PNG; retain the source and review the resulting `studio-report.json`/diagnostics before accepting a page.
