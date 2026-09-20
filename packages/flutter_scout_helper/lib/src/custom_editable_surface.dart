part of 'flutter_scout_binding.dart';

/// Declares one custom editor as an explicit Scout text-input capability.
///
/// The child boundary must contain exactly one [EditableText] whose controller
/// and focus node are identical to the registered objects. Keep unrelated
/// overlays and loading shields outside this boundary: in debug builds the
/// boundary is the authority Scout uses to distinguish the editor's own visual
/// input surface from external occlusion. The wrapper is transparent outside
/// debug builds.
class ScoutExplicitEditableSurface extends StatelessWidget {
  const ScoutExplicitEditableSurface({
    super.key,
    required this.policyVersion,
    required this.controller,
    required this.focusNode,
    required this.child,
  });

  static const int currentPolicyVersion = 1;

  final int policyVersion;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return child;
    return _ScoutExplicitEditableRenderBoundary(
      policyVersion: policyVersion,
      controller: controller,
      focusNode: focusNode,
      child: child,
    );
  }
}

class _ScoutExplicitEditableRenderBoundary
    extends SingleChildRenderObjectWidget {
  const _ScoutExplicitEditableRenderBoundary({
    required this.policyVersion,
    required this.controller,
    required this.focusNode,
    required super.child,
  });

  final int policyVersion;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  _RenderScoutExplicitEditableSurface createRenderObject(
    BuildContext context,
  ) =>
      _RenderScoutExplicitEditableSurface(policyVersion, controller, focusNode);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScoutExplicitEditableSurface renderObject,
  ) {
    renderObject
      ..policyVersion = policyVersion
      ..controller = controller
      ..focusNode = focusNode;
  }
}

class _RenderScoutExplicitEditableSurface extends RenderProxyBox {
  _RenderScoutExplicitEditableSurface(
    this._policyVersion,
    this._controller,
    this._focusNode,
  );

  int _policyVersion;
  TextEditingController _controller;
  FocusNode _focusNode;
  int registrationGeneration = 0;

  int get policyVersion => _policyVersion;
  set policyVersion(int value) {
    if (value == _policyVersion) return;
    _policyVersion = value;
    registrationGeneration += 1;
  }

  TextEditingController get controller => _controller;
  set controller(TextEditingController value) {
    if (identical(value, _controller)) return;
    _controller = value;
    registrationGeneration += 1;
  }

  FocusNode get focusNode => _focusNode;
  set focusNode(FocusNode value) {
    if (identical(value, _focusNode)) return;
    _focusNode = value;
    registrationGeneration += 1;
  }

  @override
  void attach(PipelineOwner owner) {
    registrationGeneration += 1;
    super.attach(owner);
  }
}
