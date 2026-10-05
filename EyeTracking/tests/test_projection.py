import argparse
import json
import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

from screen_eye_tracking.backend import (
    Calibration,
    Detection,
    DisplayGeometry,
    GazeEstimate,
    GazeEstimator,
    GazeFeature,
    GazeJumpGate,
    LipMotionEstimator,
    OneEuroFilter,
    ScreenProjector,
    camera_resolution_arg,
    crop_detection,
    eye_iris_metrics,
    feature_distance_m,
    is_head_turned,
    parse_yolo_output,
    stable_feature_sample,
    update_blink_state,
    IRIS_IDX_481,
)


def make_feature(point: tuple[float, float], **overrides: float) -> GazeFeature:
    values = dict(
        point=point,
        eye_center_px=(320.0, 240.0),
        left_eye_px=(300.0, 240.0),
        right_eye_px=(340.0, 240.0),
        left_yaw_deg=0.0,
        left_pitch_deg=0.0,
        right_yaw_deg=0.0,
        right_pitch_deg=0.0,
        head_width_px=160.0,
        iris_diameter_px=20.0,
        eye_open=1.0,
        distance_m=0.6,
    )
    values.update(overrides)
    return GazeFeature(**values)


def make_estimate(**overrides: float) -> GazeEstimate:
    values = dict(
        yaw_deg=0.0,
        pitch_deg=0.0,
        left_yaw_deg=0.0,
        left_pitch_deg=0.0,
        right_yaw_deg=0.0,
        right_pitch_deg=0.0,
        iris_diameter_px=20.0,
        eye_open=1.0,
        agreement=1.0,
    )
    values.update(overrides)
    return GazeEstimate(**values)


class ScreenProjectorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.display = DisplayGeometry(1920, 1080, 31.5)
        self.projector = ScreenProjector(
            self.display,
            flip_x=False,
            flip_y=False,
            camera_screen_x=0.5,
            camera_screen_y=0.5,
        )
        self.left_eye = Detection(17, 1.0, 296.0, 236.0, 304.0, 244.0)
        self.right_eye = Detection(17, 1.0, 336.0, 236.0, 344.0, 244.0)
        self.eyes = [self.left_eye, self.right_eye]
        self.distance_m = 0.6

    def test_legacy_matches_existing_projection_formula(self) -> None:
        point = self.projector.project((320.0, 240.0), 0.0, 0.0, self.distance_m)

        self.assertEqual(point, (0.5, 0.5))

    def test_offscreen_raw_projection_is_not_clipped(self) -> None:
        x, y = self.projector.project((320.0, 240.0), 50.0, -50.0, self.distance_m)
        self.assertGreater(x, 1.0)
        self.assertLess(y, 0.0)


    def test_camera_fov_controls_focal_length(self) -> None:
        narrow_fov_projector = ScreenProjector(self.display, camera_fov_deg=60.0)

        self.assertEqual(narrow_fov_projector.camera_fov_deg, 60.0)
        self.assertGreater(narrow_fov_projector.focal_px, self.projector.focal_px)

    def test_full_hd_camera_center_projects_to_screen_center(self) -> None:
        projector = ScreenProjector(
            self.display,
            flip_x=False,
            flip_y=False,
            camera_screen_x=0.5,
            camera_screen_y=0.5,
            camera_width=1920,
            camera_height=1080,
        )

        self.assertEqual(projector.project((960.0, 540.0), 0.0, 0.0, self.distance_m), (0.5, 0.5))

    def test_binocular_screen_matches_legacy_when_eye_angles_match(self) -> None:
        estimate = make_estimate(
            yaw_deg=5.0,
            pitch_deg=2.0,
            left_yaw_deg=5.0,
            left_pitch_deg=2.0,
            right_yaw_deg=5.0,
            right_pitch_deg=2.0,
        )

        legacy = self.projector.project((320.0, 240.0), estimate.yaw_deg, estimate.pitch_deg, self.distance_m)
        result = self.projector.project_estimate("binocular-screen", self.eyes, estimate, self.distance_m)

        self.assertIsNone(result.fallback_reason)
        self.assertAlmostEqual(result.point[0], legacy[0], places=7)
        self.assertAlmostEqual(result.point[1], legacy[1], places=7)

    def test_binocular_convergence_returns_finite_point_for_meeting_rays(self) -> None:
        yaw = math.degrees(math.atan((20.0 * self.distance_m / self.projector.focal_px) / self.distance_m))
        estimate = make_estimate(
            yaw_deg=0.0,
            pitch_deg=0.0,
            left_yaw_deg=yaw,
            left_pitch_deg=0.0,
            right_yaw_deg=-yaw,
            right_pitch_deg=0.0,
        )

        result = self.projector.project_estimate("binocular-convergence", self.eyes, estimate, self.distance_m)

        self.assertIsNone(result.fallback_reason)
        self.assertTrue(math.isfinite(result.point[0]))
        self.assertTrue(math.isfinite(result.point[1]))
        self.assertAlmostEqual(result.point[0], 0.5, places=7)
        self.assertAlmostEqual(result.point[1], 0.5, places=7)

    def test_binocular_convergence_falls_back_for_parallel_rays(self) -> None:
        estimate = make_estimate()

        result = self.projector.project_estimate("binocular-convergence", self.eyes, estimate, self.distance_m)

        self.assertIsNotNone(result.fallback_reason)
        self.assertEqual(result.point, self.projector.project((320.0, 240.0), 0.0, 0.0, self.distance_m))


class CalibrationQualityTest(unittest.TestCase):
    def test_uses_only_recent_stable_frames(self) -> None:
        samples = [
            (1.0, make_feature((0.2, 0.3))),
            (1.02, make_feature((0.21, 0.3))),
            (1.04, make_feature((0.2, 0.31))),
            (0.1, make_feature((0.9, 0.9))),
        ]
        feature, reason = stable_feature_sample(samples, 1.05)
        self.assertIsNone(reason)
        self.assertIsNotNone(feature)
        assert feature is not None
        self.assertEqual(feature.point, (0.2, 0.3))
        self.assertIsNone(stable_feature_sample([(0.1, make_feature((0.2, 0.3)))], 1.05)[0])

    def test_rejects_samples_while_eyes_are_closed(self) -> None:
        samples = [
            (1.0, make_feature((0.2, 0.3), eye_open=0.1)),
            (1.02, make_feature((0.2, 0.3), eye_open=0.1)),
            (1.04, make_feature((0.2, 0.3), eye_open=0.1)),
        ]
        feature, reason = stable_feature_sample(samples, 1.05)
        self.assertIsNone(feature)
        self.assertEqual(reason, "Eyes appear closed; keep them open")

    def test_saves_only_after_held_out_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.json"
            calibration = Calibration(path, fit_count=9)
            samples = [
                ((0.5, 0.5), (0.5, 0.5)),
                ((0.1, 0.1), (0.12, 0.12)),
                ((0.9, 0.1), (0.88, 0.12)),
                ((0.9, 0.9), (0.88, 0.88)),
                ((0.1, 0.9), (0.12, 0.88)),
                ((0.5, 0.1), (0.5, 0.12)),
                ((0.5, 0.9), (0.5, 0.88)),
                ((0.1, 0.5), (0.12, 0.5)),
                ((0.9, 0.5), (0.88, 0.5)),
            ]
            for raw, target in samples:
                calibration.capture(make_feature(raw), target)
            self.assertFalse(path.exists())
            calibration.validate(make_feature((0.3, 0.7)), (0.31, 0.69))
            calibration.validate(make_feature((0.7, 0.3)), (0.69, 0.31))
            self.assertTrue(path.exists())
            payload = json.loads(path.read_text())
            self.assertEqual(payload["raw_projection"], "unclipped-v2")
            self.assertIn("rbf", payload)
            self.assertIsNone(payload["geometry"])

    def test_geometry_fit_recovers_true_eye_weights(self) -> None:
        display = DisplayGeometry(1920, 1080, 31.5)
        projector = ScreenProjector(display, flip_x=False, flip_y=False, camera_screen_x=0.5, camera_screen_y=0.5)
        reprojector = lambda feature, wx, wy: projector.project_features(  # noqa: E731
            feature, "binocular-screen", weight_x=wx, weight_y=wy
        )
        true_wx, true_wy = 0.7, 0.6
        features = []
        targets = []
        offsets = ((-30.0, -20.0), (0.0, -25.0), (30.0, -20.0), (-35.0, 0.0), (0.0, 0.0), (35.0, 0.0), (-30.0, 20.0), (0.0, 25.0), (30.0, 20.0))
        angles = ((-15.0, -10.0), (0.0, -10.0), (15.0, -10.0), (-15.0, 0.0), (0.0, 0.0), (15.0, 0.0), (-15.0, 10.0), (0.0, 10.0), (15.0, 10.0))
        for (dx, dy), (yaw, pitch) in zip(offsets, angles):
            center = (320.0 + dx, 240.0 + dy)
            feature = make_feature(
                (0.5, 0.5),
                eye_center_px=center,
                left_eye_px=(center[0] - 20.0, center[1]),
                right_eye_px=(center[0] + 20.0, center[1]),
                left_yaw_deg=yaw,
                right_yaw_deg=yaw * 0.98,
                left_pitch_deg=pitch,
                right_pitch_deg=pitch * 1.02,
                iris_diameter_px=8.74,
            )
            live_point = projector.project_features(feature, "binocular-screen")
            feature = make_feature(
                live_point,
                eye_center_px=center,
                left_eye_px=feature.left_eye_px,
                right_eye_px=feature.right_eye_px,
                left_yaw_deg=yaw,
                right_yaw_deg=yaw * 0.98,
                left_pitch_deg=pitch,
                right_pitch_deg=pitch * 1.02,
                iris_diameter_px=8.74,
            )
            features.append(feature)
            targets.append(
                projector.project_features(feature, "binocular-screen", weight_x=true_wx, weight_y=true_wy)
            )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.json"
            calibration = Calibration(path, reprojector=reprojector, fit_count=9)
            for feature, target in zip(features, targets):
                calibration.capture(feature, target)
            self.assertIsNotNone(calibration.pending_matrix)
            assert calibration.pending is not None
            self.assertAlmostEqual(calibration.pending["geometry"]["eye_position_weight_x"], true_wx)
            self.assertAlmostEqual(calibration.pending["geometry"]["eye_position_weight_y"], true_wy)
            self.assertLess(calibration.pending["error"], 0.05)

    def test_ignores_old_clipped_calibration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.json"
            path.write_text(json.dumps({"affine": [[1, 0], [0, 1], [0, 0]]}))
            self.assertIsNone(Calibration(path).matrix)

    def test_loads_v1_affine_calibration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.json"
            path.write_text(json.dumps({"raw_projection": "unclipped-v1", "affine": [[1, 0], [0, 1], [0, 0]]}))
            calibration = Calibration(path)
            self.assertIsNotNone(calibration.matrix)
            self.assertEqual(calibration.apply((0.25, 0.75)), (0.25, 0.75))

    def test_rejects_collapsed_raw_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.json"
            calibration = Calibration(path, fit_count=9)
            for target in [(0.5, 0.5), (0.12, 0.12), (0.88, 0.12), (0.88, 0.88), (0.12, 0.88), (0.5, 0.12), (0.5, 0.88), (0.12, 0.5), (0.88, 0.5)]:
                calibration.capture(make_feature((0.5, 0.5)), target)
            self.assertFalse(path.exists())
            self.assertEqual(calibration.samples, [])


class OneEuroFilterTest(unittest.TestCase):
    def test_converges_on_constant_signal(self) -> None:
        filt = OneEuroFilter()
        output = None
        for index in range(60):
            output = filt.filter(0.5, index * 0.033)
        self.assertAlmostEqual(output, 0.5, places=4)

    def test_tracks_steps_faster_than_stillness(self) -> None:
        filt = OneEuroFilter()
        for index in range(30):
            filt.filter(0.0, index * 0.033)
        before = filt.x
        filt.filter(1.0, 30 * 0.033)
        self.assertGreater(filt.x - before, 0.05)


class IrisMetricsTest(unittest.TestCase):
    @staticmethod
    def make_eye(radius_y: float, radius_x: float) -> np.ndarray:
        eye = np.zeros((481, 3), dtype=np.float32)
        for order, index in enumerate(IRIS_IDX_481):
            angle = 2.0 * math.pi * order / 8.0
            eye[index] = (radius_y * math.cos(angle), radius_x * math.sin(angle), 0.0)
        return eye

    def test_circular_iris_reports_diameter_and_full_openness(self) -> None:
        diameter, open_ratio, contour = eye_iris_metrics(self.make_eye(5.0, 5.0))
        self.assertAlmostEqual(diameter, 10.0, places=3)
        self.assertAlmostEqual(open_ratio, 1.0, places=3)
        self.assertEqual(len(contour), 8)

    def test_squashed_iris_reports_low_openness(self) -> None:
        _, open_ratio, _ = eye_iris_metrics(self.make_eye(1.0, 5.0))
        self.assertLess(open_ratio, 0.35)


class FeatureDistanceTest(unittest.TestCase):
    def test_prefers_iris_distance_when_plausible(self) -> None:
        feature = make_feature((0.5, 0.5), iris_diameter_px=11.7)
        distance = feature_distance_m(feature, 320.0)
        self.assertAlmostEqual(distance, 0.0117 * 320.0 / 11.7, places=6)

    def test_falls_back_to_head_width(self) -> None:
        feature = make_feature((0.5, 0.5), iris_diameter_px=0.0, head_width_px=160.0)
        distance = feature_distance_m(feature, 320.0)
        self.assertAlmostEqual(distance, 0.16 * 320.0 / 160.0, places=6)


class ProjectorRetuneTest(unittest.TestCase):
    def test_retune_scales_focal_and_weights(self) -> None:
        projector = ScreenProjector(DisplayGeometry(1920, 1080, 31.5), camera_fov_deg=90.0)
        base_focal = projector.focal_px
        projector.retune(1.4, 0.5, 0.1)
        self.assertAlmostEqual(projector.effective_focal_px, base_focal * 1.4)
        self.assertEqual(projector.eye_position_weight_x, 0.5)
        self.assertEqual(projector.eye_position_weight_y, 0.1)
        self.assertLess(projector.effective_fov_deg(), 90.0)


class GazeJumpGateTest(unittest.TestCase):
    def test_drops_isolated_jump_and_accepts_confirmed_glance(self) -> None:
        gate = GazeJumpGate()
        self.assertEqual(gate.accept((0.1, 0.1), 0.0), (0.1, 0.1))
        self.assertIsNone(gate.accept((0.9, 0.9), 0.03))
        self.assertEqual(gate.accept((0.12, 0.1), 0.06), (0.12, 0.1))
        self.assertIsNone(gate.accept((0.9, 0.9), 0.09))
        self.assertEqual(gate.accept((0.91, 0.89), 0.12), (0.91, 0.89))


class CameraResolutionArgTest(unittest.TestCase):
    def test_accepts_presets_and_dimensions(self) -> None:
        self.assertEqual((camera_resolution_arg("VGA").width, camera_resolution_arg("VGA").height), (640, 480))
        self.assertEqual(
            (camera_resolution_arg("Full HD").width, camera_resolution_arg("Full HD").height),
            (1920, 1080),
        )
        self.assertEqual((camera_resolution_arg("1080p").width, camera_resolution_arg("1080p").height), (1920, 1080))
        self.assertEqual(
            (camera_resolution_arg("1280x720").width, camera_resolution_arg("1280x720").height),
            (1280, 720),
        )

    def test_rejects_duplicate_aliases_and_invalid_values(self) -> None:
        for value in ("2MP", "not-a-size", "1280x0"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    camera_resolution_arg(value)


class YoloWholeBody28ParserTest(unittest.TestCase):
    @staticmethod
    def output(candidate_count: int) -> np.ndarray:
        return np.zeros((1, 32, candidate_count), dtype=np.float32)

    @staticmethod
    def set_box(output: np.ndarray, index: int, cx: float, cy: float, width: float, height: float) -> None:
        output[0, 0, index] = cx
        output[0, 1, index] = cy
        output[0, 2, index] = width
        output[0, 3, index] = height

    @staticmethod
    def set_score(output: np.ndarray, index: int, class_id: int, score: float) -> None:
        output[0, 4 + class_id, index] = score

    def test_maps_classes_and_scales_direct_resize_boxes(self) -> None:
        output = self.output(3)
        self.set_box(output, 0, 320.0, 240.0, 200.0, 220.0)
        self.set_score(output, 0, 7, 0.8)
        self.set_box(output, 1, 270.0, 230.0, 30.0, 20.0)
        self.set_score(output, 1, 17, 0.21)
        self.set_box(output, 2, 370.0, 230.0, 30.0, 20.0)
        self.set_score(output, 2, 17, 0.22)

        result = parse_yolo_output(output, 0.75, image_w=1280, image_h=720)
        head, eyes = result.head, result.eyes

        self.assertIsNotNone(head)
        assert head is not None
        self.assertEqual(head.class_id, 7)
        self.assertAlmostEqual(head.x1, 440.0)
        self.assertAlmostEqual(head.y1, 195.0)
        self.assertAlmostEqual(head.x2, 840.0)
        self.assertAlmostEqual(head.y2, 525.0)
        self.assertEqual([eye.class_id for eye in eyes], [17, 17])
        self.assertLess(eyes[0].x1, eyes[1].x1)

    def test_head_uses_score_threshold_and_eye_uses_fixed_threshold(self) -> None:
        output = self.output(3)
        self.set_box(output, 0, 320.0, 240.0, 200.0, 220.0)
        self.set_score(output, 0, 7, 0.79)
        self.set_box(output, 1, 270.0, 230.0, 30.0, 20.0)
        self.set_score(output, 1, 17, 0.19)
        self.set_box(output, 2, 370.0, 230.0, 30.0, 20.0)
        self.set_score(output, 2, 17, 0.20)

        no_detection = parse_yolo_output(output, 0.8)
        detection = parse_yolo_output(output, 0.79)
        head, eyes = detection.head, detection.eyes

        self.assertIsNone(no_detection.head)
        self.assertEqual(no_detection.eyes, [])
        self.assertIsNotNone(head)
        self.assertEqual(len(eyes), 1)
        self.assertAlmostEqual(eyes[0].score, 0.20, places=6)

    def test_applies_class_specific_nms(self) -> None:
        output = self.output(5)
        self.set_box(output, 0, 320.0, 240.0, 220.0, 220.0)
        self.set_score(output, 0, 7, 0.9)
        self.set_box(output, 1, 322.0, 242.0, 220.0, 220.0)
        self.set_score(output, 1, 7, 0.85)
        self.set_box(output, 2, 260.0, 230.0, 30.0, 20.0)
        self.set_score(output, 2, 17, 0.7)
        self.set_box(output, 3, 262.0, 231.0, 30.0, 20.0)
        self.set_score(output, 3, 17, 0.6)
        self.set_box(output, 4, 380.0, 230.0, 30.0, 20.0)
        self.set_score(output, 4, 17, 0.65)

        result = parse_yolo_output(output, 0.5)
        head, eyes = result.head, result.eyes

        self.assertIsNotNone(head)
        assert head is not None
        self.assertAlmostEqual(head.score, 0.9)
        self.assertEqual([round(eye.score, 2) for eye in eyes], [0.7, 0.65])

    def test_selects_mouth_with_head_threshold_inside_head(self) -> None:
        low_output = self.output(2)
        self.set_box(low_output, 0, 320.0, 240.0, 220.0, 220.0)
        self.set_score(low_output, 0, 7, 0.9)
        self.set_box(low_output, 1, 320.0, 300.0, 40.0, 20.0)
        self.set_score(low_output, 1, 19, 0.49)

        self.assertIsNone(parse_yolo_output(low_output, 0.5).mouth)

        output = self.output(5)
        self.set_box(output, 0, 320.0, 240.0, 220.0, 220.0)
        self.set_score(output, 0, 7, 0.9)
        self.set_box(output, 1, 320.0, 300.0, 40.0, 20.0)
        self.set_score(output, 1, 19, 0.19)
        self.set_box(output, 2, 320.0, 300.0, 40.0, 20.0)
        self.set_score(output, 2, 19, 0.6)
        self.set_box(output, 3, 322.0, 301.0, 40.0, 20.0)
        self.set_score(output, 3, 19, 0.5)
        self.set_box(output, 4, 600.0, 450.0, 40.0, 20.0)
        self.set_score(output, 4, 19, 0.95)

        result = parse_yolo_output(output, 0.5)

        self.assertIsNotNone(result.mouth)
        assert result.mouth is not None
        self.assertEqual(result.mouth.class_id, 19)
        self.assertAlmostEqual(result.mouth.score, 0.6)


class LipMotionEstimatorTest(unittest.TestCase):
    def test_mouth_crop_uses_vsdlm_margins(self) -> None:
        image = np.arange(4 * 4 * 3, dtype=np.uint8).reshape((4, 4, 3))
        crop = crop_detection(
            image,
            Detection(19, 1.0, 1.0, 1.0, 3.0, 3.0),
            4,
            4,
            margin_top=2,
            margin_bottom=6,
            margin_left=2,
            margin_right=2,
        )

        self.assertEqual(crop.shape, (4, 4, 3))
        np.testing.assert_array_equal(crop, image)

    def test_onnx_model_accepts_zero_mouth_crop(self) -> None:
        model_path = Path("public/models/vsdlm_l.onnx")
        if not model_path.exists():
            self.skipTest(f"{model_path} is not available")
        estimator = LipMotionEstimator(model_path, "cpu")
        probability = estimator.estimate(np.zeros((30, 48, 3), dtype=np.uint8), Detection(19, 1.0, 0.0, 0.0, 48.0, 30.0))

        self.assertTrue(math.isfinite(probability))


class BlinkHysteresisTest(unittest.TestCase):
    def test_hysteresis_deadband(self) -> None:
        self.assertTrue(update_blink_state(False, 0.2))
        # Between the close and reopen thresholds the state holds.
        self.assertTrue(update_blink_state(True, 0.36))
        self.assertFalse(update_blink_state(False, 0.36))
        self.assertFalse(update_blink_state(True, 0.6))

    def test_nan_holds_closed_and_is_ignored_when_open(self) -> None:
        self.assertTrue(update_blink_state(True, float("nan")))
        self.assertFalse(update_blink_state(False, float("nan")))


class HeadTurnGateTest(unittest.TestCase):
    def test_collapsed_eye_span_is_treated_as_turned(self) -> None:
        self.assertFalse(is_head_turned(60.0, 160.0))
        self.assertTrue(is_head_turned(25.0, 160.0))
        self.assertFalse(is_head_turned(float("nan"), 160.0))


class GazeEstimatorModelTest(unittest.TestCase):
    def test_onnx_model_produces_finite_mesh(self) -> None:
        model_path = Path("public/models/gaze_Nx3x160x160.onnx")
        if not model_path.exists():
            self.skipTest(f"{model_path} is not available")
        estimator = GazeEstimator(model_path, "cpu")
        rng = np.random.default_rng(0)
        output = estimator.session.run(
            [estimator.output.name],
            {estimator.input.name: rng.random((1, 3, 160, 160), dtype=np.float32)},
        )[0]

        self.assertEqual(list(output.shape), [1, 962, 3])
        self.assertTrue(np.isfinite(output).all())

    def test_estimate_on_synthetic_frame_returns_finite_angles_or_known_error(self) -> None:
        model_path = Path("public/models/gaze_Nx3x160x160.onnx")
        if not model_path.exists():
            self.skipTest(f"{model_path} is not available")
        estimator = GazeEstimator(model_path, "cpu")
        estimator.warmup()
        frame = np.zeros((480, 640, 3), dtype=np.uint8)
        head = Detection(7, 1.0, 200.0, 120.0, 440.0, 360.0)
        eyes = [
            Detection(17, 1.0, 270.0, 220.0, 290.0, 240.0),
            Detection(17, 1.0, 350.0, 220.0, 370.0, 240.0),
        ]
        try:
            estimate = estimator.estimate(frame, head, eyes)
        except ValueError as error:
            self.assertIn("gaze vector", str(error))
            return
        for value in (estimate.yaw_deg, estimate.pitch_deg, estimate.eye_open, estimate.agreement, estimate.iris_diameter_px):
            self.assertTrue(math.isfinite(value))


if __name__ == "__main__":
    unittest.main()
