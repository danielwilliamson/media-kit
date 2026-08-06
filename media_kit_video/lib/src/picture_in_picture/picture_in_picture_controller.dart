/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:media_kit_video/src/picture_in_picture/pip_event.dart';
import 'package:media_kit_video/src/picture_in_picture/picture_in_picture_android.dart';
import 'package:media_kit_video/src/picture_in_picture/picture_in_picture_ios.dart';
import 'package:media_kit_video/src/picture_in_picture/picture_in_picture_noop.dart';

/// Platform-agnostic Picture-in-Picture controller exposed on
/// [VideoController.pictureInPicture].
///
/// Consumers typically do not create instances directly. Instead, they
/// configure Picture-in-Picture declaratively by passing a [PipConfig] to
/// [Video.pip], which drives this controller internally. The imperative API
/// is available for advanced use cases (manual start/stop, lifecycle
/// observation).
abstract class PictureInPictureController {
  /// Creates a platform-specific instance of [PictureInPictureController].
  /// On unsupported platforms / OS versions this returns a no-op
  /// implementation whose [isSupported] resolves to `false`.
  factory PictureInPictureController.platform() {
    if (Platform.isIOS) return PictureInPictureIOS();
    if (Platform.isAndroid) return PictureInPictureAndroid();
    return const PictureInPictureNoop();
  }

  /// Whether the current device and OS version support Picture-in-Picture.
  ///
  /// Implementations must not throw; unsupported conditions resolve to
  /// `false`.
  Future<bool> isSupported();

  /// Whether a Picture-in-Picture session is currently active.
  Future<bool> isActive();

  /// Attaches the controller to a media_kit video output and optionally
  /// starts a session.
  ///
  /// [handle] is the native libmpv handle associated with the
  /// [VideoController]. [videoSize] is the intrinsic video size used for
  /// the aspect ratio of the Picture-in-Picture window. When [autoEnter]
  /// is `true`, entering Picture-in-Picture automatically on backgrounding
  /// is enabled. When [startImmediately] is `true`, the session starts
  /// right after the first frame is rendered.
  ///
  /// On unsupported platforms this is a no-op.
  Future<void> start({
    required int handle,
    required Size videoSize,
    bool autoEnter = true,
    bool startImmediately = false,
  });

  /// Stops any active Picture-in-Picture session and releases platform
  /// resources.
  Future<void> stop();

  /// Enables or disables the "enter on backgrounding" behavior while a
  /// session is attached.
  Future<void> setAutoEnter({required bool enabled});

  /// Toggles linear-playback mode in the PiP UI. When `true`, AVKit hides
  /// the scrubber and 15s skip buttons in the PiP overlay — use to gate
  /// seek for non-entitled users so they can't bypass an in-app paywall.
  ///
  /// iOS-only; no-op on Android (system PiP doesn't expose seek controls
  /// to gate) and on the no-op platform.
  Future<void> setRequiresLinearPlayback({required bool required});

  /// Pushes playback metadata used by the platform's PiP UI to render
  /// pause-vs-stop, progress bar, and skip controls. Without this the
  /// system falls back to "live stream" UI (stop button, no progress,
  /// greyed-out FF/RW). Pass any combination of fields — missing fields
  /// keep the previously-pushed value.
  ///
  /// Currently a no-op on Android (system PiP doesn't use a delegate
  /// for these) and on the no-op platform.
  Future<void> setMetadata({
    Duration? duration,
    Duration? position,
    bool? isPlaying,
  });

  /// The on-screen video rect (logical points) the restore animation should
  /// return the PiP window to. Null falls back to the platform default.
  ///
  /// iOS only; a no-op on Android (system PiP animates to its own source rect)
  /// and on the no-op platform.
  Future<void> setSourceRect(Rect? rect);

  /// Broadcast stream of Picture-in-Picture lifecycle and playback control
  /// events.
  Stream<PipEvent> get events;
}
