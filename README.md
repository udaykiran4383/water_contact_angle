# Contact Angle Analyzer (Sessile Drop)

This project measures sessile-drop contact angle from an image and reports:
- left/right contact angle
- mean contact angle
- hysteresis
- uncertainty
- fit quality per method

## Project Goal

Build a mobile-friendly analyzer that is not only visually plausible, but scientifically defensible:
- robust baseline detection
- stable contact-point detection
- droplet-only contour extraction
- multi-method fitting with explicit rejection of weak fits

## What Was Wrong

From the failing outputs and overlays, the main problems were in computer-vision geometry extraction:
- image/frame border edges were leaking into contour extraction
- contact points were sometimes computed from noisy/global contour data
- droplet isolation could collapse to one flank on difficult images
- circle/ellipse/Young-Laplace were then rejected, leaving polynomial as the only valid method

This produced unstable fit behavior across different images, even when the droplet looked simple.

## Root-Cause Summary

The previous pipeline had failure coupling:
1. contour contamination (frame/border artifacts)
2. contact points detected before strict droplet isolation
3. shape fits run on partially wrong geometry
4. method rejection looked correct, but happened too late

## Backend Fixes Implemented

### 1) Edge and contour robustness
- Added border-point suppression immediately after edge detection to remove frame artifacts.
- Updated connected-component selection from "largest component" to a geometric score:
  - favors tall, centered, plausible droplet components
  - penalizes border-touching and over-wide components

### 2) Droplet isolation and ordering fix
- Reordered flow: isolate droplet contour first, then detect contact points.
- Removed an over-aggressive top-arc cut that could split the droplet into one-sided contours.
- Added flank-support checks so selected droplet contour must contain both left and right near-baseline structure.

### 3) Contact-point detection fix
- Contact points now come from the isolated droplet arc using side-aware weighted estimation.
- Added vertical-support checks around candidate contacts.
- Retained conservative fallback only when primary detection is not reliable.

### 4) Fit validity hardening
- Circle fit now includes geometric consistency with detected contact points:
  - fitted circle must intersect baseline coherently
  - predicted intersection points must align with detected left/right contacts
  - center-below-baseline and contact-mismatch cases are rejected
- Fit rejection reasons are explicit in output.

### 5) Numerical stability
- Circle solver is normalized least-squares (better conditioning for arc-only data).
- Circle quality metric uses normalized radial RMSE instead of unstable variance-based R².
- Gaussian blur now handles image borders correctly (no zero-padding artifacts).

## Current Processing Pipeline

1. decode image and grayscale conversion
2. optional inversion based on mean intensity
3. sub-pixel edge detection
4. border-edge suppression
5. geometric connected-component selection
6. baseline detection + alignment transform
7. droplet contour isolation (above baseline)
8. contact-point detection from isolated contour
9. fit methods:
   - circle
   - ellipse
   - local polynomial tangent
   - Young-Laplace
10. validity gating + weighted ensemble
11. uncertainty estimation
12. annotated overlay and CSV-ready metrics

## Method Acceptance Rules

A method contributes only if valid. Typical rejection reasons:
- low R²
- circle/contact mismatch
- invalid ellipse axes or extreme aspect ratio
- polynomial left/right mismatch
- Young-Laplace high residual or invalid Bond number

This is intentional: invalid methods are excluded from final angle and uncertainty weighting.

## Scientific Precision Upgrades (ADSA)

The contact-angle engine was upgraded for metrology-grade precision:

### Axisymmetric Drop Shape Analysis (Young–Laplace)
`lib/processing/young_laplace.dart` was rewritten as a proper ADSA solver — the
reference method used by commercial tensiometers:

- **Physics:** integrates the dimensionless Bashforth–Adams form of the
  Young–Laplace equation (apex-radius–scaled arc-length ODE) with a small-step
  RK4 integrator and a singularity-free apex start (L'Hôpital limit).
- **Fitting:** a multi-start **Nelder–Mead simplex** minimises the true
  **geometric (orthogonal) distance** from every contour point to the
  theoretical meridian, over `[Bond number, apex radius, apex x, apex z]`.
  Robust trimmed residuals bound outlier leverage. This replaces the old
  144-point grid search, the Δx-only residual, and the hand-picked Bond number.
- **Contact angle:** read directly as the tangent angle φ at the baseline
  crossing of the best-fit profile (no linear interpolation of raw data).
- **Validation:** `test/young_laplace_adsa_test.dart` recovers known
  spherical-cap contact angles (50–150°) to within 2°, with R²>0.97, and is
  robust to ~1 px contour noise. On the real PFOTES drops it matches the
  reference LBADSA tool (≈112–117°) to within ~3°.

### Robust back-lit silhouette extraction
`lib/processing/silhouette_extractor.dart` is a new primary geometry path for
the standard lab capture (a dark, back-lit drop on a bright diffuse
background). Gradient/Canny edge detection fails on these because the dark drop
**merges into the dark substrate** (no edge between them) and an internal bright
refraction window creates spurious interior edges. The silhouette extractor
instead uses the strong contrast that *does* exist — bright background vs. dark
object:

- **Otsu threshold** splits bright background from dark foreground.
- **Substrate baseline** is the dominant "top-of-object" level across columns
  (robust to the drop and to a partial-width stage block), accepted only where
  bright background sits above it (rejects frame-edge dark bands), then fit as a
  possibly-tilted line and refined from the substrate immediately adjacent to
  the drop.
- **Drop isolation** via connected components confined to *above* the baseline —
  this cleanly separates the drop from the substrate it touches and from
  background artifacts.
- **Outer-edge row scan** traces the true silhouette and is immune to the
  interior refraction window. Crucially, for contact angles >90° the drop bulges
  *beyond* the contact points, so the full outline is kept (the legacy
  contact-span narrowing would have clipped the very curvature that defines the
  angle).

The legacy edge pipeline remains as an automatic fallback when the scene is not
a confident back-lit silhouette.

**Region of interest (ROI).** Before measuring, the user can drag a box around
the droplet (`lib/widgets/roi_select_screen.dart` → `DropRoi` →
`ImageProcessor.processImage(file, roi: ...)`). The extractor confines its
threshold, baseline and drop search to that window — the standard ADSA workflow
for excluding background contamination or neighbouring features. The baseline is
located by the *lower* cluster of column tops (a high percentile, not the
median) so it stays correct even inside a tight ROI where the drop spans more
columns than the surrounding substrate.

### Validation against reference ground truth
`PFOTES/ground_truth.csv` records the contact angles measured by the reference
**LBADSA** tool for the 12 PFOTES drop photos (transcribed from the fitting
screenshots in `PFOTES/Fitting/`). `test/pfotes_ground_truth_test.dart` runs the
full pipeline against them:

- **ADSA fits all 12/12 drops** (was 4/12 before this work).
- **Mean error ≈ 1.45°, median error ≈ 1.4°, max error ≈ 3.7°** vs. the reference
  tool — within LBADSA's own inter-operator reproducibility (~2–3°), with **no
  outliers**.
- The previously reported 22° "outlier" on `C_1.5%_2 coat_5` was a transcription
  typo in the ground truth (`112.439` → correct `132.439`, confirmed against
  `PFOTES/Fitting/Screenshot (589).png`). The automatic full-frame fit had always
  been accurate on this drop (~2.6°); no manual ROI is needed.

(Before this work the same drops measured with ~32° mean error and frequent 90°
fallbacks.)

### Synthetic ground-truth harness
Because the 12 LBADSA reference values are themselves manual fits (~2–3° own
uncertainty), `test/synthetic_precision_test.dart` renders **anti-aliased
spherical-cap silhouettes whose contact angle is known exactly** (dark drop +
dark stage on a bright back-light; the 50%-intensity edge lands on the analytic
boundary). This measures true pipeline accuracy against ground truth:

- Clean caps (95–145°): **ensemble MAE ≈ 0.22°, ADSA MAE ≈ 0.14°, max ≈ 0.47°.**
- Stress (sensor noise, ±4–5° stage tilt, small R=65px drops): **MAE ≈ 0.51°,
  max ≈ 1.8°.**
- `test/geometry_fit_test.dart` pins the primitive fits to exact analytic
  circles/ellipses (center, axes, geometric R² ≈ 1).

Precision work driven by these harnesses (all validated to improve recovery
against *known* truth without regressing the PFOTES reference):

1. **Sub-pixel silhouette edges.** The back-lit row scan now refines each flank
   to the 50%-coverage intensity crossing instead of the integer outer-object
   column, so the ADSA fit sees sub-pixel contours (the integer index alone
   capped every point at ±0.5 px). Biggest gains on tilt/small-drop cases.
2. **Working circle method.** The circle R² was a radial-variance ratio whose
   denominator collapses for a clean arc, so good fits scored ~0 and were
   rejected — exactly backwards. Replaced with a well-conditioned geometric R²
   (comparable to the ellipse/ADSA R²). A circle is the exact model for a cap,
   so this is now the most accurate method under tilt.
3. **Working ellipse method.** Fixed three bugs: the conic-center sign, the
   Halir–Flusser eigenvector selection (a plain power iteration returned the
   wrong conic — now a proper 3×3 characteristic-cubic eigensolver picks the
   eigenvector satisfying `4AC−B²>0`), and a `q`-sign error in the cubic solver.
   Ellipse parameters are transformed out of the normalized frame directly
   (robust) rather than by denormalizing the raw conic coefficients.
4. **Sub-pixel gradient edge sign.** The legacy parabolic peak offset had a
   flipped sign, nudging refined edges the wrong way; corrected.

### Reflective-substrate (specular stage) support
Surface-science stages are often specular (silicon wafers, glass, polished
metal), so a back-lit drop casts a mirror image below the surface. The true
baseline is the **axis of mirror symmetry** of the drop+reflection silhouette,
not the bottom of that blob — mis-reading it inflates the angle (the classic
"is the shadow considered?" problem). `test/reflection_baseline_test.dart`
renders drops on stages of varying reflectivity with an exactly-known baseline:

- **Matte & moderate stages:** the substrate-top detector already places the
  baseline at **0.0 px** error (< 0.3° angle error) — unchanged.
- **Strong mirror stages:** the old code had no dark substrate to lock onto, so
  it fell back to the legacy path (up to **1.6°** error). A new specular baseline
  detector (`SilhouetteExtractor._specularBaseline`) finds the surface as the
  sub-pixel symmetry axis of the drop+reflection blob — detected by its narrow
  "waist" (contact line) flanked by the drop and reflection lobes. It runs only
  when that strict two-lobe symmetry is present, so matte back-lit capture is
  untouched. Result: strong-mirror baseline error **0.0 px**, angle error
  **< 0.26°** (was up to 1.6°). A `reflection_score` is reported for QC.

### Fit-quality metrics
- Ellipse R² is now the standard geometric `1 − SS_res/SS_tot` using true
  closest-point distances (replacing an `exp(−res)` surrogate that inflated
  apparent quality).

### Ensemble & uncertainty
- A near-perfect ADSA fit (R²≥0.97, low residual) now **anchors** the ensemble
  instead of being down-weighted as an "outlier" against geometrically cruder
  circle/polynomial fits. It is also exempt from the cross-method outlier
  filter and the leave-one-out consistency penalty in that regime.
- Bootstrap uncertainty uses a **circular moving-block bootstrap** so the
  spatial correlation of contour points no longer under-estimates the
  confidence interval.

### Note on the `PFOTES/Fitting/Screenshot (*).png` files
These are desktop screenshots of reference ADSA software, not droplet photos,
and should not be treated as analysis inputs (they conveniently display the
ground-truth contact angles used to validate the upgrades above).

## Scientific Notes

- Without real scale calibration, physical units are approximate.
- For publication-grade physical metrics, include known scale (or valid metadata calibration).
- Good image practices:
  - level substrate
  - sharp focus at triple line
  - minimal reflection/glare
  - crop around droplet with margin

## Run and Verify

### Local checks
```bash
flutter test
flutter analyze
```

### Run on device
```bash
flutter devices
flutter run -d <device_id>
```

## Files Updated for This Fix

Core algorithm updates:
- `lib/image_processor.dart`
- `lib/processing/angle_utils.dart`
- `lib/processing/sub_pixel_edge.dart`

Coverage:
- `test/angle_utils_test.dart`

## Remaining Limitations

- Very low-contrast contact lines can still force polynomial fallback.
- Strong substrate reflections can still degrade Young-Laplace validity.
- Automatic baseline detection is robust but still image-dependent for highly noisy captures.

## Practical Interpretation of Output

- `Valid methods: 3/4` (or similar) is normal.
- `Valid methods: 1/4` repeatedly across images means contour/contact extraction is still weak for that acquisition condition.
- If only polynomial survives consistently, improve capture quality or add controlled preprocessing for that specific camera setup.

