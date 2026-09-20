# ScholarsEye artwork

`ScholarsEyeArtwork.png` is the original generated artwork, retained unchanged.
`ScholarsEyeArtworkBeige.png` is the current background-only edit, preserving the
liked black crayon eye on a subtle warm beige canvas (approximately `#F4EFE5`).
`ScholarsEyeAppIcon.png` packages the beige artwork inside smooth native rounded tile bounds;
`package-icon.swift` is the deterministic native packaging source. The cached
`ScholarsEye.icns` was created with Apple's `sips` and `iconutil` and contains all
standard and Retina icon sizes. The normal build copies this icon into the app
bundle and adds `CFBundleIconFile`. This also avoids `iconutil`'s codec-service
restriction in a shell sandbox, where it misleadingly reports "Invalid Iconset."

To regenerate the PNG and ICNS after an artwork change, run
`SCHOLARSEYE_REBUILD_ICON=1 zsh scripts/build-macos.sh` in an ordinary terminal.

`DoodleEye.swift` is the native, scalable companion mark, inspired by the same
user-provided crayon drawing. It draws a fixed imperfect outline, pupil, and
lashes, with one short blink about every six seconds. It does not animate while
`blinking` is false or when Accessibility Reduce Motion is enabled. The mark is
static during recording.

## Generation provenance

Tool: built-in `image_gen` (not the API/CLI fallback), 2026-09-17.
Reference: user's black crayon eye doodles, upper-right eye with eyelashes.

Initial prompt:

> Use case: logo-brand. Asset type: production macOS app icon, square 1024×1024.
> Reference image role: user-provided style and eye-shape reference, specifically
> the cute crayon eye at upper center/right. Create a single memorable eye doodle
> for ScholarsEye: imperfect almost oval eye outline with an uneven charcoal/crayon
> black stroke, black round hand-scribbled pupil, four or five little eyelashes on
> the top and three small bottom lashes. Preserve the playful naive child-drawn
> quality and visible dry crayon texture; asymmetrical but clear and friendly.
> Center the one eye in generous whitespace, occupying approximately 64% of tile
> width. Black artwork on a clean white gently rounded square app-icon tile;
> beyond the rounded tile corners truly transparent. No text, no extra symbols,
> no blue, no gradient, no photographic scene, no drop shadow, no multiple icons,
> no glossy effects. Single icon only. Eye should read at 32 pixels.

First edge-refinement prompt:

> Use case: precise-object-edit. Edit target: this generated ScholarsEye app icon.
> Change ONLY the white rounded-square tile background and its perimeter. Keep the
> black crayon eye drawing, pupil, all lashes, their proportions and placement
> exactly as they are. Make the white tile completely clean solid white with a
> geometrically smooth continuous rounded-square edge, inset 5% from the square
> canvas, and make everything outside this one tile genuinely transparent. Remove
> ALL stray white/black flecks outside the tile and ALL textured ragged border
> artifacts. No shadow. Do not smooth the eye: its crayon texture must remain.
> Output a single square PNG app icon, 1024x1024.

Final edit prompt (eliminates the generated transparency mask's perimeter flecks):

> Use case: precise-object-edit. Preserve the black crayon eye drawing EXACTLY:
> same pupil, outline, five upper lashes, three bottom lashes, same location and
> size. Replace ALL background with a solid, perfectly flat, opaque pure white
> #FFFFFF canvas from edge to edge. There must be NO transparency at all, NO
> rounded-square tile silhouette, NO border, NO shadow, NO paper texture, NO specks
> in the outer whitespace. The entire image is a perfectly opaque square white
> PNG with just this single centered black crayon eye. Keep the eye itself's dry
> black crayon texture intact. This white square artwork will be packaged into a
> native macOS icon separately. 1024x1024.

The generated artwork is 1254×1254. The packaged PNG is 1024×1024 RGBA.

## Beige background edit

Tool: built-in `image_gen` edit (not the API/CLI fallback), 2026-09-20.
Edit target: `ScholarsEyeArtwork.png`; original remains unchanged.
Output: `ScholarsEyeArtworkBeige.png`, then native packaging into
`ScholarsEyeAppIcon.png` and all-size `ScholarsEye.icns`.

Final prompt:

> Use case: precise-object-edit. Asset type: existing ScholarsEye macOS application
> logo artwork. Image 1 is the edit target. Change ONLY the plain white background
> to a solid, very subtle warm beige approximately #F4EFE5, including the negative
> space within the eye. Preserve the existing black child-drawn crayon eye exactly:
> same uneven oval outline, same pupil, all five upper eyelashes, all three lower
> eyelashes, same position, same proportions, same size, same black crayon grain
> and flecked stroke edges. Do not redraw, smooth, stylize, enlarge, shrink, or
> otherwise change the eye. Keep the canvas square, opaque, with the warm beige
> color extending fully to every edge. No transparency, no border, no rounded
> tile shape, no gradient, no shadows, no text, no new marks, no added paper
> texture. This artwork will be packaged as a native rounded macOS icon separately.
