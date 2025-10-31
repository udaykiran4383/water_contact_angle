import 'package:flutter/material.dart';
import '../utils/app_colors.dart';

class IITBombayLogo extends StatelessWidget {
  final double size;
  final bool showTagline;

  const IITBombayLogo({
    Key? key,
    this.size = 100,
    this.showTagline = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Official IIT Bombay Logo Container
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBlue.withOpacity(0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Image.network(
              'https://hebbkx1anhila5yf.public.blob.vercel-storage.com/Indian_Institute_of_Technology_Bombay_Logo.svg-oogRtGScrsqNLOiSfKMt9eruF7ycrG.png',
              width: size * 0.85,
              height: size * 0.85,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return _FallbackLogo(size: size);
              },
            ),
          ),
        ),
        if (showTagline) ...[
          const SizedBox(height: 16),
          // MEMS Department Branding
          Column(
            children: [
              Text(
                'MEMS',
                style: TextStyle(
                  fontSize: size * 0.22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Metallurgical Engineering &\nMaterials Science',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size * 0.09,
                  fontWeight: FontWeight.w600,
                  color: AppColors.darkGray,
                  height: 1.4,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppColors.primaryBlue.withOpacity(0.2),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  'Prof. S. Mallick',
                  style: TextStyle(
                    fontSize: size * 0.08,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBlue,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// Compact Logo for Header
class IITBombayLogoCompact extends StatelessWidget {
  final double size;

  const IITBombayLogoCompact({
    Key? key,
    this.size = 56,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Image.network(
          'https://hebbkx1anhila5yf.public.blob.vercel-storage.com/Indian_Institute_of_Technology_Bombay_Logo.svg-oogRtGScrsqNLOiSfKMt9eruF7ycrG.png',
          width: size * 0.8,
          height: size * 0.8,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return _FallbackLogo(size: size);
          },
        ),
      ),
    );
  }
}

// Fallback Logo if image fails to load
class _FallbackLogo extends StatelessWidget {
  final double size;

  const _FallbackLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primaryBlue,
            AppColors.primaryCyan,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'IIT',
              style: TextStyle(
                fontSize: size * 0.3,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'BOMBAY',
              style: TextStyle(
                fontSize: size * 0.12,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryCyan,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Animated Logo for Splash/Loading
class AnimatedIITBombayLogo extends StatefulWidget {
  final double size;
  final bool showTagline;

  const AnimatedIITBombayLogo({
    Key? key,
    this.size = 100,
    this.showTagline = true,
  }) : super(key: key);

  @override
  State<AnimatedIITBombayLogo> createState() => _AnimatedIITBombayLogoState();
}

class _AnimatedIITBombayLogoState extends State<AnimatedIITBombayLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );

    _rotateAnimation = Tween<double>(begin: -15, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Transform.rotate(
            angle: _rotateAnimation.value * 3.14159 / 180,
            child: IITBombayLogo(
              size: widget.size,
              showTagline: widget.showTagline,
            ),
          ),
        );
      },
    );
  }
}

// Logo with MEMS Badge
class IITBombayLogoWithBadge extends StatelessWidget {
  final double size;

  const IITBombayLogoWithBadge({
    Key? key,
    this.size = 100,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IITBombayLogoCompact(size: size),
        Positioned(
          bottom: -8,
          right: -8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.accentGreen,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accentGreen.withOpacity(0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'MEMS',
              style: TextStyle(
                fontSize: size * 0.12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
