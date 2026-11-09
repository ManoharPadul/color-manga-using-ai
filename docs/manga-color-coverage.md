# Color coverage and manual repair

Coverage reports are CPU-only diagnostics that compare the source, raw model result, final color image, region annotations and protected masks. Neutral regions are ambiguous: white and gray can be intentional paper, hair, clothing, shadows, eyes, or uncolored content. The report therefore suggests review regions rather than treating every neutral pixel as a defect.

The desktop workbench supports painted masks, category/palette assignment, repair candidates, preview, and accept/reject. Candidates should be checked against the original and the nearby panel objects. An accepted change is bounded to the approved mask; the source is never overwritten. See the UI and workflow settings for current detail/geometry controls.

Automatic coverage analysis is not a semantic segmentation model and cannot reliably determine whether a patch is skin, hair, or fabric. Use a manually approved mask when a correction matters. Keep uncertain areas unchanged until visually checked.
