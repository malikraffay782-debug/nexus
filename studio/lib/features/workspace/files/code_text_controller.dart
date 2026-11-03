import 'package:flutter/material.dart';

/// TextEditingController that can colour Python source. Falls back to plain
/// text for big files and while the keyboard is composing (IME underline).
class CodeTextController extends TextEditingController {
  CodeTextController();

  bool highlightPython = false;

  static const int _maxHighlightLength = 60000;

  // Groups: 1 comment, 2 string, 3 keyword, 4 number.
  static final RegExp _py = RegExp(
    r'(#[^\n]*)'
    r'|("""[\s\S]*?"""'
    r"|'''[\s\S]*?'''"
    r'|"(?:\\.|[^"\\\n])*"'
    r"|'(?:\\.|[^'\\\n])*')"
    r'|\b(and|as|assert|async|await|break|class|continue|def|del|elif|else|'
    r'except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|'
    r'pass|raise|return|try|while|with|yield|True|False|None|self)\b'
    r'|\b(\d+(?:\.\d+)?)\b',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing =
        withComposing && value.composing.isValid && !value.composing.isCollapsed;
    if (!highlightPython || composing || text.length > _maxHighlightLength) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final comment = dark ? const Color(0xFF6A9955) : const Color(0xFF2E7D32);
    final string = dark ? const Color(0xFFCE9178) : const Color(0xFFB5502B);
    final keyword = dark ? const Color(0xFFC586C0) : const Color(0xFF7B1FA2);
    final number = dark ? const Color(0xFFB5CEA8) : const Color(0xFF0B6B3A);

    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _py.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final Color color;
      if (m.group(1) != null) {
        color = comment;
      } else if (m.group(2) != null) {
        color = string;
      } else if (m.group(3) != null) {
        color = keyword;
      } else {
        color = number;
      }
      spans.add(TextSpan(text: m[0], style: TextStyle(color: color)));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(style: style, children: spans);
  }
}
