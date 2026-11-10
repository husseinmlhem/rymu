import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A single, short entrance; it never delays initialization or navigation.
class RymuStartupMark extends StatefulWidget {
  const RymuStartupMark({super.key, this.width = 88, this.height = 48});
  final double width;
  final double height;

  @override
  State<RymuStartupMark> createState() => _RymuStartupMarkState();
}

class _RymuStartupMarkState extends State<RymuStartupMark>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 480));
  late final _curve =
      CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
    } else if (!_started) {
      _entrance.forward();
    }
    _started = true;
  }

  @override
  void dispose() {
    _curve.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Rymu',
        image: true,
        child: FadeTransition(
          opacity: Tween<double>(begin: .5, end: 1).animate(_curve),
          child: ScaleTransition(
            scale: Tween<double>(begin: .94, end: 1).animate(_curve),
            child: SvgPicture.asset('assets/rymu-mark.svg',
                excludeFromSemantics: true,
                width: widget.width,
                height: widget.height,
                colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.onSurface, BlendMode.srcIn)),
          ),
        ),
      );
}
