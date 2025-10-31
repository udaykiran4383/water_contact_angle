import 'package:flutter/material.dart';

class MEMSLogo extends StatelessWidget {
  final double size;
  final Color? primaryColor;
  final Color? accentColor;

  const MEMSLogo({
    Key? key,
    this.size = 80,
    this.primaryColor,
    this.accentColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final primary = primaryColor ?? const Color(0xFF1E3A8A);
    final accent = accentColor ?? const Color(0xFF06B6D4);

    return SizedBox(
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [primary, accent],
          ),
          boxShadow: [
            BoxShadow(
              color: primary.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: EdgeInsets.all(size * 0.15),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'MEMS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: size * 0.02,
                      height: 1.0,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: size * 0.06),
                  Container(
                    width: size * 0.38,
                    height: size * 0.015,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(size * 0.01),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MEMSLogoSmall extends StatelessWidget {
  final double size;

  const MEMSLogoSmall({Key? key, this.size = 40}) : super(key: key);

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
            const Color(0xFF1E3A8A),
            const Color(0xFF06B6D4),
          ],
        ),
      ),
      child: Center(
        child: Text(
          'M',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
