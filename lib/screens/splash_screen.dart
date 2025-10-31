import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/app_colors.dart';
import '../screens/home_screen.dart';
import '../assests/logo.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
  with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final AnimationController _pulse;
  late final Animation<double> _scale;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0, // Start fully visible - no fade in needed
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    // Gentle breathing/pulse animation for the logo (scale + glow)
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.98, end: 1.02).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _glow = Tween<double>(begin: 0.2, end: 0.55).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );

    // Already at full opacity, just maintain it
    // No need to call forward()

    // Keep the MEMS logo visible for 5 seconds before entering Home
    Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const HomeScreen(),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: anim,
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.lightGray,
              AppColors.lightGray.withOpacity(0.95),
              Colors.white.withOpacity(0.98),
            ],
          ),
        ),
        child: SafeArea(
          minimum: const EdgeInsets.all(24),
          child: Center(
            child: FadeTransition(
              opacity: _fade,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Animated logo with glow effect - properly constrained
                    ScaleTransition(
                      scale: _scale,
                      child: Container(
                        width: 200,
                        height: 200,
                        alignment: Alignment.center,
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            // Soft animated glow behind the logo
                            AnimatedBuilder(
                              animation: _glow,
                              builder: (context, _) {
                                return Container(
                                  width: 180,
                                  height: 180,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        AppColors.primaryCyan
                                            .withOpacity(0.15 + (0.25 * _glow.value)),
                                        AppColors.primaryCyan
                                            .withOpacity(0.08 + (0.12 * _glow.value)),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.0, 0.6, 1.0],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.primaryCyan
                                            .withOpacity(0.3 + (0.35 * _glow.value)),
                                        blurRadius: 40 + (50 * _glow.value),
                                        spreadRadius: -3,
                                      ),
                                      BoxShadow(
                                        color: AppColors.primaryBlue
                                            .withOpacity(0.18 + (0.25 * _glow.value)),
                                        blurRadius: 65 + (75 * _glow.value),
                                        spreadRadius: -8,
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            // Logo itself with proper size - no clipping needed
                            const MEMSLogo(size: 150),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),
                    // App title with fade animation
                    FadeTransition(
                      opacity: _fade,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            Text(
                              'Water Contact Angle Analyzer',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryBlue,
                                letterSpacing: 0.5,
                                height: 1.3,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryCyan.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: AppColors.primaryCyan.withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                'IIT Bombay MEMS',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primaryCyan,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            const SizedBox(height: 32),
                            // Animated loading indicator with better styling
                            Column(
                              children: [
                                SizedBox(
                                  width: 200,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: LinearProgressIndicator(
                                      backgroundColor: 
                                          AppColors.primaryCyan.withOpacity(0.15),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        AppColors.primaryCyan,
                                      ),
                                      minHeight: 3,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Loading...',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.primaryBlue.withOpacity(0.6),
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
