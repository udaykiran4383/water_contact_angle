# Capture Guide — Back-lit Sessile-Drop Imaging

How to capture phone images that approach lab-goniometer accuracy. The physics
of the accuracy gap between a phone and a ₹15-lakh Krüss/Biolin/ramé-hart unit is
**almost entirely in the optics and alignment, not the sensor** — those units
reach ±0.1° with a ~1 MP monochrome camera. So the wins below are about geometry,
lighting, and exposure, which the in-app **Camera** screen now helps you control.

## The rig (what you already have)
LED panel → drop on the X/Z stage → phone on the mount, viewed **side-on**. Keep
all three centred on one horizontal axis.

## The five things that matter (in order of impact)

1. **Level the optical axis with the baseline (anti-parallax).** The camera must
   look at the drop edge-on, not down or up at it. Even a few degrees of tilt
   biases the baseline and both contact points. Use the in-app **teal baseline
   guide line** — line it up with the drop's contact line. This is the single
   biggest error source after the reference itself.
2. **Uniform, bright back-light.** Put the LED panel directly behind the drop and
   **diffuse it** (one sheet of paper/diffuser) so the background is an even
   bright field. The sub-pixel edge is taken at the **50%-intensity crossing**
   between bright background and dark drop — any vignetting/gradient shifts that
   crossing unevenly around the contour. Block room light; use only the backlight.
3. **Expose DOWN — never clip the highlights.** Bias exposure to about **−1 EV**
   (the in-app slider defaults there). The bright field should sit *just below*
   pure white and the drop should be solidly dark. Over-exposure blooms the
   highlights into the drop and eats the edge. This preserves the crisp bright→dark
   ramp the detector needs.
4. **Lock focus.** Tap the drop in the **Camera** screen to focus+lock. Autofocus
   hunting changes the magnification between shots. A telecentric lab lens keeps
   scale constant; a phone can't, so at least freeze it.
5. **Shoot from farther with crop, not close-up wide.** Place the phone
   **~15–20 cm** back and let the drop fill a good fraction of the frame (crop/
   optical zoom). Greater distance makes the chief rays more parallel → less
   near/far perspective error across the ~1–3 mm drop (poor-man's telecentricity).

## Camera settings (handled by the in-app Camera, or set these in Pro mode)
| Setting | Value | Why |
|---|---|---|
| Focus | Manual/locked (tap drop) | AF hunting changes scale |
| Exposure | ≈ −1 EV, no clipping | preserve the 50% edge, avoid blooming |
| ISO | lowest (50–100) | noise jitters the sub-pixel edge |
| Shutter | 1/125–1/500 s static; ≥1/1000 s dynamic | sharpness / freeze contact line |
| White balance | fixed/manual | AF-WB shifts the edge intensity ramp |
| Resolution | maximum (RAW/DNG if available) | more edge pixels; linear intensity |
| HDR / AI-scene / beauty | **OFF** | tone-mapping/sharpening warps the edge |
| Flash | **OFF** | destroys the silhouette |
| Aspect | 4:3 | uses the full sensor |

## Framing
Drop centred, filling ~50–80% of frame width, with **both** triple-points and the
drop's reflection/baseline visible (the reflection is used to pin the true
baseline). Use a timer/remote so tapping doesn't shake the rig.

## Realistic expectation
With the above, peer-reviewed back-lit phone setups match a Krüss unit **within
~1°** on static angles and **±2–3°** on dynamic ones. Our pipeline validates at
**MAE ≈ 1.45°** vs LBADSA on the PFOTES set and **≈0.2–0.5°** on synthetic
ground truth — so capture quality, not the algorithm, is now the limiting factor.

## Sources
Krüss DSA, Biolin Attension Theta, ramé-hart 190/290, DataPhysics OCA spec sheets
(±0.1° accuracy, monochrome LED backlight, telecentric-lens option); DropletLab
smartphone contact-angle guides; Nature Sci. Reports 2023 (ML orthogonal-camera
goniometry). Telecentric-lens theory: opto-e.com, vision-doctor.com.
