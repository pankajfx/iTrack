import 'package:flutter/material.dart';

/// Modal busy overlay with an optional label — shown during submissions
/// (tracker create, photo processing) so users can't double-submit.
class LoadingOverlay extends StatelessWidget {
  final bool visible;
  final String? label;
  final Widget child;

  const LoadingOverlay({
    super.key,
    required this.visible,
    this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (visible)
          Positioned.fill(
            child: AbsorbPointer(
              child: Container(
                color: Colors.black45,
                alignment: Alignment.center,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        if (label != null) ...[
                          const SizedBox(height: 14),
                          Text(label!),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
