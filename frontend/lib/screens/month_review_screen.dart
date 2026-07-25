import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../api_service.dart';
import 'main_screen.dart';

class MonthReviewScreen extends StatefulWidget {
  final Map<String, dynamic> event;

  const MonthReviewScreen({Key? key, required this.event}) : super(key: key);

  @override
  _MonthReviewScreenState createState() => _MonthReviewScreenState();
}

class _MonthReviewScreenState extends State<MonthReviewScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isLoading = false;

  late double unusedBudget;
  late double savingsReserveRemaining;
  late bool reserveDipped;
  late String eventId;

  @override
  void initState() {
    super.initState();
    unusedBudget = (widget.event['unusedBudget'] ?? 0.0).toDouble();
    savingsReserveRemaining = (widget.event['savingsReserveRemaining'] ?? 0.0).toDouble();
    reserveDipped = widget.event['reserveDipped'] == true;
    eventId = widget.event['id'] ?? '';
  }

  void _finishReview(double amount) async {
    setState(() => _isLoading = true);
    try {
      await ApiService.transferReserveToGoals(eventId, amount);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainScreen(firstName: "User")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  void _nextPage() {
    if (_hasSecondPage) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    } else {
      _finishReview(0);
    }
  }

  bool get _hasSecondPage => !reserveDipped && savingsReserveRemaining > 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (idx) => setState(() => _currentPage = idx),
            children: [
              _buildPage1(),
              if (_hasSecondPage) _buildPage2(),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2DBE7F)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPage1() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 48.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.celebration_rounded,
            size: 100,
            color: Color(0xFF2DBE7F),
          ),
          const SizedBox(height: 32),
          Text(
            "Month Ended!",
            style: GoogleFonts.outfit(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Your unused budget of Rs ${unusedBudget.toStringAsFixed(0)} was automatically added to your goals! Great job staying on track.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 18,
              color: const Color(0xFF475569),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 48),
          ElevatedButton(
            onPressed: _nextPage,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2DBE7F),
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              elevation: 0,
            ),
            child: Text(
              "Continue",
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage2() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 48.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.savings_rounded,
            size: 100,
            color: Color(0xFF2DBE7F),
          ),
          const SizedBox(height: 32),
          Text(
            "Untouched Reserve",
            style: GoogleFonts.outfit(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "You have Rs ${savingsReserveRemaining.toStringAsFixed(0)} in your Savings Reserve untouched. Do you want to add this to your goals too?",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 18,
              color: const Color(0xFF475569),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 48),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              OutlinedButton(
                onPressed: () => _finishReview(0),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  side: const BorderSide(color: Color(0xFF2DBE7F), width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: Text(
                  "No",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF2DBE7F),
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () => _finishReview(savingsReserveRemaining),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DBE7F),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  "Yes, add it!",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
