# Presenter's Guide — Automated Sessile-Drop Contact Angle Analyzer

**Deck:** `BTP_Presentation_Contact_Angle_Analyzer.pdf` (20 slides, ~15–18 min talk + questions)
**Golden rule:** every number you say is reproducible from the project's test suite. If challenged, say so — it is your strongest card.

---

## The five numbers to memorise

| Number | What it is | Where it comes from |
|---|---|---|
| **0.106°** | mean absolute error vs *exact* synthetic truth, 60–145° | `test/synthetic_precision_test.dart` |
| **0.135°** | same, under stress (noise, tilt, blur, small drops, shadow) | same test, 12 stress cases |
| **1.56°** | MAE vs laboratory LB-ADSA on 12 PFOTES drops (~1.2% relative) | `test/pfotes_ground_truth_test.dart` |
| **21.2° → 7.3°** | external DropletLab dataset, before → after our baseline research | `test/dropletlab_dataset_test.dart` |
| **₹18,000** | fabricated instrument cost (vs ≈ ₹15 lakh commercial) | Stage-I hardware work |

---

## Glossary — "what is what" (know these cold)

- **Contact angle (θ):** the angle the liquid surface makes with the solid, measured *through the liquid* at the point where liquid, solid and vapour meet. Below 90° = hydrophilic, above = hydrophobic, above 150° = superhydrophobic.
- **Sessile drop:** a drop sitting on a surface (as opposed to a hanging/pendant drop). We photograph it side-on as a silhouette.
- **Baseline:** the line in the image where the solid surface is — the drop's contact points lie on it. *Getting this line right is the single biggest accuracy factor.*
- **Back-lit silhouette:** LED panel behind the drop → the drop appears as a dark shape on a bright field. This gives the sharpest, most reliable edge.
- **Young's equation:** γ_SV − γ_SL = γ_LV·cos θ — the force balance that makes θ a material property.
- **Young–Laplace / Bashforth–Adams:** the differential equation for the exact shape of a drop under surface tension + gravity. Fitting it to the observed profile is called **ADSA** (Axisymmetric Drop Shape Analysis) — the reference method used by commercial instruments.
- **Bond number (β):** dimensionless measure of gravity vs surface tension for the drop. β→0 means the drop is a perfect spherical cap; large β means gravity flattens it. If β is tiny, the Young–Laplace fit "degenerates" — the angle is still valid but surface tension is not extractable.
- **Sub-pixel edge:** for an anti-aliased image, the true edge lies where intensity crosses 50% between background and object levels — we can locate the edge to a *fraction* of a pixel, not just the nearest pixel.
- **Ensemble:** we fit four independent models (circle, ellipse, tangent polynomial, Young–Laplace) and combine only the ones that pass validity checks, weighted by fit quality.
- **MAE:** mean absolute error.
- **Parity plot:** measured value vs reference value; perfect agreement = points on the y = x line.
- **LB-ADSA:** the ImageJ plugin (Stalder 2010) our lab used as reference for the PFOTES drops.
- **PFOTES:** the fluorosilane coating series measured in our lab (θ ≈ 112–134°).
- **DropletLab dataset:** a published, openly licensed set of drop images (Teflon substrate, four liquids) we used as an *external* test we did not control.

---

## Slide-by-slide script

Speak it naturally — these are lines you can say almost verbatim. *(Italics = optional if short on time.)*

### Slide 1 — Title
> "Good afternoon. I'm Uday Kiran, and this is my B.Tech project under Prof. Mallick: an automated sessile-drop contact angle analyzer — a complete instrument, hardware plus software, that measures contact angles on a smartphone, and, importantly, is quantitatively validated at every step."

### Slide 2 — Motivation
> "Contact angle is the primary measurement of wetting — it matters for coatings, adhesion, superhydrophobic surfaces. Commercial goniometers do this to a tenth of a degree, but they cost about fifteen lakh rupees.
> The key observation that motivated this project: those instruments use quite ordinary one-to-five-megapixel cameras. Their accuracy comes from the **optics and the software** — not the sensor. A phone camera outclasses those sensors. So if we build a careful optical bench and write rigorous software, we should get close to lab-grade results. Our fabricated instrument cost about eighteen thousand rupees — over 95% cheaper."

### Slide 3 — Physics
> "Quickly, the physics. Young's equation makes θ a material property — a balance of three interfacial tensions. The *shape* of the drop is governed by the Young–Laplace equation — here in Bashforth–Adams form — where β, the Bond number, measures how much gravity flattens the drop. Two things to note: when β is near zero the drop is just a spherical cap; and a useful exact bound — the angle can never be less than 2·atan(height over half-width) — which we later use as a physical sanity check on our fits."

### Slide 4 — Error sources ⭐ (this slide justifies everything after it)
> "Before showing our design, here is where error actually comes from — this is from published error analysis in *Soft Matter*, 2019. A **single pixel** of error in placing the baseline costs about half a degree to one degree below 150°, and up to eight degrees near 180°. Even seven experts analysing the *same image* spread over ten degrees.
> So the design rules are clear: detect the baseline algorithmically to sub-pixel precision, make the drop as large in the frame as possible, and propagate baseline sensitivity into every reported uncertainty. The table maps each known error source to how we address it — the rest of the talk walks through these."

### Slide 5 — System overview
> "The system: a fabricated optical bench, and a Flutter application whose entire analysis pipeline is written in native Dart — no external vision library in the measurement path. That means the same code runs on the phone, on my laptop, and in automated tests. Analysis takes two to five seconds per image. The pipeline has five stages — capture, silhouette extraction, baseline detection, fitting, and the validity-gated ensemble."

### Slide 6 — Hardware
> "This is the instrument. On the left, the complete setup: LED back-light panel, the sample stage in the middle, and the phone mount — all on an acrylic base. On the right, the fabricated stage: a scissor lift for height and a micrometer translation stage for lateral positioning.
> We first tried sourcing off-the-shelf precision parts locally — prohibitively expensive at low volume — so we pivoted to a fully-constrained SolidWorks parametric design and had it professionally fabricated. Credit to my partners Dixit and Anandu for the hardware work. Total: about eighteen thousand rupees."

### Slide 7 — Capture
> "Since capture geometry dominates the error budget, the in-app camera enforces discipline. The phone's accelerometer drives a live level badge — roll for baseline levelling, green within half a degree, and pitch, where the ISO standard recommends looking zero to four degrees *downward* so the contact points are visible. Tap-to-focus **locks** focus, because autofocus hunting changes magnification. Exposure is biased minus one EV so the bright field never clips — clipping destroys the sub-pixel edge. And after every shot, the app itself checks for clipping and contrast, and asks for a retake if the frame would degrade the measurement."

### Slide 8 — Silhouette extraction
> "Why not just use a standard edge detector like Canny? Because in these images the dark drop merges into the dark substrate — there is *no edge* between them — while the bright refraction window inside the drop creates strong *false* edges. So we work from the one reliable contrast: bright background versus dark object. Otsu threshold, connected component above the baseline, then a row-by-row scan of the *outermost* pixels — that outer scan is inherently immune to anything inside the drop.
> Then every edge point is refined to the 50%-intensity crossing — sub-pixel. Integer edges alone cap you at half a pixel, which is about half a degree on a small drop."

### Slide 9 — Baseline hierarchy ⭐ (your most original engineering slide)
> "Because the baseline dominates the error budget, we don't have one detector — we have four, each matched to a physical type of substrate.
> On a matte dark stage, the substrate's top edge clusters across columns — a robust line fit, with a check that support spans both flanks.
> On mirror-like stages, there is no dark band at all — instead the drop and its reflection form a shape symmetric about the surface. We find the baseline as that symmetry axis. The idea that *the reflection is signal, not noise* goes back to DropSnake.
> On glossy mid-gray substrates — like Teflon viewed slightly from above — the surface is *brighter than the threshold* and invisible to the first detector; we find it as a soft intensity step on the columns beside the drop.
> And finally, the contact line itself is found as the *corner* where the drop's edge meets its reflection's edge — the same signal used by Krüss's commercial software and by a patented method.
> The detectors are arbitrated by strict precedence rules, and every result records *which* detector fired, so the measurement is auditable."

### Slide 10 — Fitting methods
> "Four independent fits. A circle — exact for small drops. An ellipse, using the numerically stable Halir–Flusser method. A polynomial tangent — with one twist: fitting in image coordinates fails on steep profiles because the curve folds over; we rotate into the local tangent frame first, which removed a five-degree bias at 145°.
> And the reference method — full Young–Laplace, ADSA: we integrate the Bashforth–Adams equation with Runge–Kutta and fit with *orthogonal* distances, excluding the optically distorted two-pixel band at the contact line and extrapolating the fitted curve to the baseline — standard ADSA practice. Two physical gates reject degenerate solutions.
> One methodological point I want to highlight: the size of that exclusion band was chosen by *measurement* — we tested a proportional band and it was strictly worse. Design decisions in this project are made by experiment, not intuition."

### Slide 11 — Uncertainty
> "Every angle we report comes with an uncertainty, combined from five terms — and the dominant one is baseline placement, for which there is an exact formula: dθ/dh equals one over r·sin θ. That formula reproduces the published half-degree-per-pixel plateau and the blow-up near 180°.
> On top of that, the result card shows ISO-style quality flags — high-angle regime, tilted stage, left–right asymmetry, drop too small — so a user knows not just the number, but whether to trust it."

### Slide 12 — Validation methodology ⭐
> "Now — how do we know any of this is right? Three independent tiers. First, synthetic images where the angle is known *exactly* — this is the only true ground truth, because even laboratory references are themselves fits. Second, our lab's LB-ADSA reference measurements. Third, a published external dataset we did not control.
> And critically: every threshold is locked into an automated test suite. If any future change degrades accuracy, the build fails. Our accuracy claims are regression-guarded."

### Slide 13 — Tier 1 results
> "Against exact truth, across 60 to 145 degrees: mean absolute error 0.106 degrees — every single angle within 0.2. Under stress — sensor noise, five degrees of stage tilt, defocus blur, drops half the size, contact shadows — 0.135 degrees. I'll point out one: the five-degree tilt case used to cost us 1.76 degrees; after we fixed the contour handling it costs 0.08."

### Slide 14 — Tier 2 results (parity plot)
> "Against the laboratory: twelve PFOTES drops, referenced to LB-ADSA fits. The parity plot shows our measurement against the reference — the points sit on the identity line. MAE 1.56 degrees, about 1.2% relative.
> An important scientific point: these residuals are zero-mean scatter at the level of the *reference method's own* operator variability — the published spread between experts is larger than this. Tuning further against twelve samples would be over-fitting, so we deliberately stopped."

### Slide 15 — Tier 3 results
> "The hardest test: a published external dataset with everything our rig avoids — needles in the drops, glossy substrates, faint reflections, low resolution. Initially we scored about 21 degrees of error — and instead of hiding that, we root-caused it: the visible surface line on those images is the substrate's *far edge*, not the contact line. Implementing the glossy-step and junction-corner detectors brought it to 7.3 degrees — while our primary-rig results stayed **bit-for-bit identical**. And note: the references there are themselves fits on needle-distorted drops, so 7.3° bounds the disagreement of *both* methods."

### Slide 16 — The problem sketch ⭐ (your personal-contribution moment)
> "I want to show you one problem in detail, because we identified it ourselves before finding it in the literature. This is my working sketch. When a drop overhangs, the back-light is blocked underneath — the drop, its shadow and its reflection merge into one dark region, and *two* plausible baselines appear: the true contact plane, and the shadow boundary below it. Given half a degree per pixel, choosing wrong costs tens of degrees.
> We solved it with four methods working together: treating the reflection as signal through mirror symmetry; the glossy step detector; the junction-corner detector — the drop edge and its reflection meet in a corner, and that corner *is* the contact point; and strict arbitration rules between them."

### Slide 17 — Case study result
> "Here is the result on a real capture from our rig. Left: the raw image with the shadow wedge. Right: our pipeline — the baseline locks onto the substrate line and the contact points sit exactly at the wedge apexes. The drop reads 134.95 degrees with left–right agreement of one-hundredth of a degree, and three independent methods agree within a degree and a half.
> And it is *proven*, not anecdotal: we built synthetic wedge images with exactly known angles — the pipeline recovers 150° to within a third of a degree, and 135° to three-hundredths. Those are locked in as regression tests."

### Slide 18 — Limitations
> "Honest boundaries. One regime still defeats us: on some external glycerol images, a soft shadow halo widens *monotonically* — there is no corner, no waist, nothing geometric to detect — and we lose 12 to 20 degrees there. We know the fix from the literature — a mirrored-model image-energy fit — and it's scoped as future work. Small drops are flagged, and above 150 degrees we warn, consistent with published advice.
> Each of these is *measured* on named images and documented — characterised, not hidden."

### Slide 19 — Conclusions
> "To conclude: 0.106 degrees against exact truth. 1.56 degrees against the laboratory — at the reference's own noise floor. A three-fold improvement on an adversarial external dataset with zero regression at home. An instrument at 1% of commercial cost. And every claim reproducible from an automated test suite of 27 tests. This is a validated instrument, not just an app."

### Slide 20 — Thank you
> "Thank you. I'm happy to take questions — and every number in this talk can be regenerated by running the project's validation suite."

---

## Anticipated professor questions — and answers

**Q: How do you know your synthetic tests reflect reality?**
> The synthetics are rendered by 8×8 supersampling, which places the true edge exactly at the 50%-intensity crossing — the same physical model as a real anti-aliased silhouette. And they are only Tier 1: the same pipeline is checked against real lab references (Tier 2) and an external dataset (Tier 3). The three tiers agree with each other.

**Q: Your PFOTES error is 1.56° but commercial instruments claim ±0.1°. Why the gap?**
> ±0.1° is instrument *repeatability*, not agreement between two different methods. Our 1.56° is the disagreement between two complete method chains — our pipeline and a human-driven LB-ADSA fit — and published work shows even experts using the *same* software on the same image spread by several degrees. Our residuals are zero-mean, i.e., no systematic bias; the scatter is at the comparison's noise floor.

**Q: Why not machine learning?**
> Classical methods are precise (0.1°) where the physics is followed; ML methods published so far report 6–10° accuracy — they trade precision for robustness on messy images. Our position: physics-based first, and a small on-device segmentation model only as a *fallback* for the one regime where geometry provably has no signal (the shadow-skirt case). Also, classical methods are auditable — we can state *why* every number came out.

**Q: How is the baseline uncertainty term derived?**
> For a circular cap, cos α = h/r with contact half-width a = r·sin θ; differentiating gives dθ/dh = 1/(r·sin θ) = 1/a radians per pixel. It's exact for the cap and reproduces the published empirical curve — the 0.5°/pixel plateau below 150° and the divergence toward 180°.

**Q: What is the drop-size dependence?**
> Error scales inversely with the drop's size in pixels — that's both published and visible in our stress tests (the small-drop case is our largest stress error, 0.32°). The app flags drops below 100 px contact half-width; the remedy is optical — zoom or approach.

**Q: Left and right angles differ on real surfaces. How do you handle that?**
> We compute them independently in the baseline-aligned frame and report both; a difference above 4° raises a quality flag, since it means either a genuinely non-axisymmetric drop (contamination, hysteresis) or a baseline error. On our rig the agreement is typically within a degree — the shadow case study showed 0.01°.

**Q: Can it measure surface tension too?**
> The ADSA fit already estimates the Bond parameter, but for small drops it is unidentifiable — the drop is too spherical for gravity to leave a signature. We flag that regime instead of over-claiming. With scale calibration (future work) and large drops, surface tension becomes extractable — the solver is already in place.

**Q: Advancing/receding (dynamic) angles?**
> Future work: video capture with per-frame analysis over a stability plateau, reporting mean ± SD. Note √N averaging does *not* apply — vibration is temporally correlated — which is why we report the plateau SD, consistent with standard practice.

**Q: What exactly is new here versus DropSnake / OpenDrop / commercial software?**
> Individually, many ingredients are established — and we cite each origin. The contribution is the combination: fully on-device native analysis; a *hierarchy* of baseline detectors spanning matte to glossy substrates with measured arbitration rules; an ensemble anchored by an authoritative ADSA fit; a propagated uncertainty with the correct dominant term; and — most distinctively — a locked, three-tier validation harness. Most published tools validate on one tier at most.

**Q: Why is the external-dataset error (7.3°) so much larger than the lab error (1.56°)?**
> Three reasons: those images violate our capture protocol (needles, glossy substrate, low resolution); the references are themselves polynomial fits on needle-distorted drops with up to 16° of their own left–right asymmetry; and one image family (glycerol shadow-skirt) is a known open problem contributing most of the residual. On the sub-groups where the baseline is detectable, we score ~2°.

**Q (hardware): Why a phone and not a webcam/Raspberry Pi camera?**
> The phone integrates the sensor, the compute, the display and the UI in one device the user already owns — no laptop needed at the bench. And modern phone sensors outresolve the cameras in commercial goniometers; the accelerometer additionally gives us live levelling for free.

---

## Practical tips

- **Timing:** ~45–60 s per slide; slides 4, 9, 12–17 deserve the most time. If cut short, drop slides 3 and 8 details, never the validation slides.
- **Demo:** the app is installed on your phone. A strong move after slide 11: measure a drop live, and point at the uncertainty breakdown and the quality flags on the result card.
- **If asked something you don't know:** "That's a good question — the pipeline logs every intermediate quantity, so I can check and follow up." (True: `baseline_method`, per-method reasons, and reject reasons are all recorded.)
- **Vocabulary to prefer:** say "reference method" not "true value" for LB-ADSA; say "regression-guarded" when you mention tests; say "characterised" for the limitations.
- The full 15-page report (`BTP_Report_Contact_Angle_Analyzer.pdf`) has every table, figure, and all 26 references if a professor wants depth after the talk.
