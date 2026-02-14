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

