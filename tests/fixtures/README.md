# Local learning-session fixture

`learning-session.html` is self-contained test material for the native recorder. It is not ScholarsEye application UI. Open the file in a browser or serve this directory locally; it makes no network requests and uses no external assets.

## Realistic recording journey

1. Open the fixture at ordinary browser zoom. Start a native ScholarsEye screen-and-audio recording, with the fixture visible on the selected display.
2. Leave **1 · Lesson** visible for at least five seconds. Read the Python and mathematics aloud, including a genuine uncertainty such as “I expect zero, one, two, but I am not sure when the lambda reads i.”
3. Choose **2 · Problem**. Type a prediction and reasoning into **Session notes**, such as `I predict [0, 1, 2]. C12 is 1*0 + 2*2 = 4.` Keep this view visible for at least five seconds.
4. Stop typing for 10–15 seconds while reading/thinking. The native recording should continue. An unchanged display is useful coverage for static-frame handling.
5. Choose **3 · Solution**. Read the original output, corrected code, and matrix result aloud. Update the notes to explain the correction. Notes must survive switching between all three views, but are intentionally lost on page reload.
6. Keep the solution visible for at least five seconds. If testing a chunk boundary, keep recording beyond the configured chunk duration and repeat a view transition. Stop from the native app.
7. Open/play the saved native recording. Verify readable code, typed notes, small subscripts and decimal text, both view transitions, synchronized spoken explanation, and the solution markers listed below. Confirm actual duration, track presence, codec, frame timing, and bytes on disk using media inspection as well as playback.

For later post-recording idle-filter tests, take a longer genuine break with no speech or interaction. Compare this with the quiet reading interval. Neither interval should cause live idle-based pausing. A short fixture journey alone does not establish that idle filtering or two-hour capture works.

## Expected visible answers

- Original Python: `[2, 2, 2]`. All closures read the same captured `i`, which holds `2` after the comprehension.
- Corrected Python: `[lambda i=i: i for i in range(3)]`, yielding `[0, 1, 2]` when called.
- Matrix problem: `A = [[1, 2], [3, 4]]`, `B = [[2, 0], [1, 2]]`.
- `C12 = 1 × 0 + 2 × 2 = 4`; the full product is `[[4, 4], [10, 8]]`.
- Fine-detail text on Lesson: `xₙ₊₁ = xₙ − η∇f(xₙ), η = 0.01` (rendered with actual HTML subscripts).
- Solution end markers: `LAMBDA-224 · MATRIX-44108`.

The fixture exposes exactly three lesson navigation buttons and an editable notes area. It contains no answer grading, recording API, remote calls, or permanent persistence. Record actual verification results separately; these steps describe intended checks, not completed tests.
