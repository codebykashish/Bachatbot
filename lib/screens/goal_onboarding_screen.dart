import 'package:flutter/material.dart';
import '../api_service.dart';
import 'main_screen.dart';

class GoalOnboardingScreen extends StatefulWidget {
  final String firstName;
  const GoalOnboardingScreen({super.key, required this.firstName});

  @override
  State<GoalOnboardingScreen> createState() => _GoalOnboardingScreenState();
}

class _GoalOnboardingScreenState extends State<GoalOnboardingScreen> {
  bool _wantsToSetGoal = false;
  final PageController _pageController = PageController();
  int _currentPage = 0;
  
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  
  double _timeframeMonths = 12;
  int _priority = 1;
  bool _isSaving = false;

  final Color _primaryColor = const Color(0xFF2DBE7F);

  final List<String> _quickChips = [
    'Emergency Fund', 'New Phone', 'Laptop', 'Trip', 'Education', 'Wedding'
  ];

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _skip() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => MainScreen(firstName: widget.firstName, showTour: true),
      ),
    );
  }

  void _nextPage() {
    if (_currentPage == 0 && _nameController.text.trim().isEmpty) {
      _showError('Please enter a goal name');
      return;
    }
    if (_currentPage == 1 && (double.tryParse(_amountController.text) ?? 0) <= 0) {
      _showError('Please enter a valid amount');
      return;
    }
    
    // Dismiss keyboard
    FocusScope.of(context).unfocus();

    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _prevPage() {
    // Dismiss keyboard
    FocusScope.of(context).unfocus();

    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _saveGoal() async {
    setState(() => _isSaving = true);
    try {
      final payload = {
        'name': _nameController.text.trim(),
        'targetAmount': double.parse(_amountController.text),
        'timeframeMonths': _timeframeMonths.toInt(),
        'priority': _priority,
      };

      // Depending on your ApiService implementation, this could be a static method or instance method.
      // Adjust if you use ApiService().post('/goals', ...) or ApiService.createGoal(...)
      try {
        // Attempting to call standard static post method
        await ApiService.post('/goals', payload);
      } catch (_) {
        // Fallback for some common implementations if .post isn't available
        // e.g. await ApiService.createGoal(payload);
        // Just replacing this with your actual implementation.
        throw Exception("Verify API method in goal_onboarding_screen.dart -> _saveGoal()");
      }
      
      if (mounted) {
        _skip();
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to save goal: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildInitialPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _primaryColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.track_changes_rounded, size: 64, color: _primaryColor),
            ),
            const SizedBox(height: 32),
            const Text(
              'Do you want to set a savings goal?',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'People who set goals save up to 2x more. You can always set one later.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 48),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _wantsToSetGoal = true;
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryColor,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Yes, let\'s do it', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _skip,
              style: TextButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Skip for now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey[600])),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage0() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Text(
            'What are you saving for?',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Goal Name',
              hintText: 'e.g. Dream Vacation',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _primaryColor, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Quick picks:', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _quickChips.map((chip) {
              return ActionChip(
                label: Text(chip),
                onPressed: () {
                  _nameController.text = chip;
                },
                backgroundColor: _primaryColor.withOpacity(0.1),
                side: BorderSide.none,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              );
            }).toList(),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: _nextPage,
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryColor,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildPage1() {
    double amount = double.tryParse(_amountController.text) ?? 0;
    double monthlyCommitment = amount > 0 ? (amount / _timeframeMonths) : 0;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Text(
            'Set your target',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            onChanged: (val) => setState(() {}),
            decoration: InputDecoration(
              prefixText: 'Rs ',
              prefixStyle: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black87),
              hintText: '0',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _primaryColor, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text('Timeframe: ${_timeframeMonths.toInt()} months', style: const TextStyle(fontWeight: FontWeight.w600)),
          Slider(
            value: _timeframeMonths,
            min: 1,
            max: 36,
            divisions: 35,
            activeColor: _primaryColor,
            onChanged: (val) {
              setState(() {
                _timeframeMonths = val;
              });
            },
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Priority (1-10):', style: TextStyle(fontWeight: FontWeight.w600)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: _priority > 1 ? () => setState(() => _priority--) : null,
                    color: _primaryColor,
                  ),
                  Text('$_priority', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _priority < 10 ? () => setState(() => _priority++) : null,
                    color: _primaryColor,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Priority 1 = funded first. Same priority = grows side by side.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: _primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Rs ${monthlyCommitment.toStringAsFixed(0)} / month over ${_timeframeMonths.toInt()} months',
                    style: TextStyle(fontWeight: FontWeight.w600, color: _primaryColor.withOpacity(0.8)),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: OutlinedButton(
                  onPressed: _prevPage,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: const BorderSide(color: Colors.grey),
                  ),
                  child: const Icon(Icons.arrow_back, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: ElevatedButton(
                  onPressed: _nextPage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPage2() {
    double amount = double.tryParse(_amountController.text) ?? 0;
    double monthlyCommitment = amount > 0 ? (amount / _timeframeMonths) : 0;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Text(
            'Confirm your goal',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                Icon(Icons.flag_circle, size: 64, color: _primaryColor),
                const SizedBox(height: 16),
                Text(
                  _nameController.text.trim(),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Rs ${amount.toStringAsFixed(0)}',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _primaryColor),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Timeframe', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    Text('${_timeframeMonths.toInt()} months', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Monthly Commitment', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    Text('Rs ${monthlyCommitment.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Priority', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    Text('$_priority', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: OutlinedButton(
                  onPressed: _isSaving ? null : _prevPage,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: const BorderSide(color: Colors.grey),
                  ),
                  child: const Icon(Icons.arrow_back, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveGoal,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('Set Goal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          if (_wantsToSetGoal)
            TextButton(
              onPressed: _skip,
              child: const Text('Skip for now', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: SafeArea(
        child: !_wantsToSetGoal
            ? _buildInitialPrompt()
            : Column(
                children: [
                  // Progress Dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (index) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        height: 8,
                        width: _currentPage == index ? 24 : 8,
                        decoration: BoxDecoration(
                          color: _currentPage == index ? _primaryColor : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const NeverScrollableScrollPhysics(),
                      onPageChanged: (index) {
                        setState(() {
                          _currentPage = index;
                        });
                      },
                      children: [
                        _buildPage0(),
                        _buildPage1(),
                        _buildPage2(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
