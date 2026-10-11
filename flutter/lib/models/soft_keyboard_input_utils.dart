// Pure soft-keyboard text-diff helpers for the Android (non-iOS) controller input path.
//
// ponytail: the iOS handler (_handleIOSSoftKeyboardInput, remote_page.dart ~281-318) keeps its
// own inline copy of this diff; it is intentionally not rewired through here. Touching the
// already-correct iOS path purely to deduplicate would add regression risk for no behavioral
// gain. If the diff ever has to change for both platforms, unify then.

/// Computes the edit to push to the remote host given the previous (`oldValue`) and current
/// (`newValue`) soft-keyboard text-field contents, both seeded with the `'1' * N` sentinel.
///
/// Returns the number of `VK_BACK` presses to send (`backspaces`) followed by the literal text
/// to type (`insert`). Mirrors the iOS algorithm at remote_page.dart ~281-318 (minus the
/// iOS-only composing-hold). Diffs on CONTENT, not length, so Hangul/CJK in-place composing
/// mutation (ㅁ→마→만 — same UTF-16 length) is handled instead of silently dropped.
({int backspaces, String insert}) computeSoftKeyboardEdit(
    String oldValue, String newValue) {
  // Align the diff window to the text after the last sentinel '1' in each string.
  var i = newValue.length - 1;
  for (; i >= 0 && newValue[i] != '1'; --i) {}
  var j = oldValue.length - 1;
  for (; j >= 0 && oldValue[j] != '1'; --j) {}
  if (i < j) j = i;
  final subNewValue = newValue.substring(j + 1);
  final subOldValue = oldValue.substring(j + 1);

  // Compose raw jamo into syllables first: the IME sometimes appends
  // compatibility jamo without composing (notably the first syllable, where
  // the '1' sentinel confuses its language context), so diffing raw text
  // would forward "ㅇㅏㄴ" instead of "안". Already-composed text passes
  // through unchanged, so this is a no-op for the normal path.
  final composedNew = composeHangulJamo(subNewValue);
  final composedOld = composeHangulJamo(subOldValue);

  // Longest common prefix of the two composed windows.
  var common = 0;
  for (;
      common < composedOld.length &&
          common < composedNew.length &&
          composedNew[common] == composedOld[common];
      ++common) {}

  final insert =
      composedNew.length > common ? composedNew.substring(common) : '';
  final backspaces = composedOld.length - common;
  return (backspaces: backspaces, insert: insert);
}

/// Reproduces the Android clipboard guard (remote_page.dart ~331-337): when the sentinel-prefixed
/// buffer is replaced by pasted text (old starts with '1', new does not), treat the old value as
/// empty so the whole new text is sent.
///
/// Both `isNotEmpty` checks are required: `_value` starts empty and seeding the controller text
/// does not fire `onChanged`, so the first keystroke can arrive with an empty `oldValue`; without
/// the guards `oldValue[0]` would throw a RangeError.
String clipboardAdjustedOldValue(String oldValue, String newValue) {
  if (oldValue.isNotEmpty &&
      newValue.isNotEmpty &&
      oldValue[0] == '1' &&
      newValue[0] != '1') {
    return '';
  }
  return oldValue;
}

const _autoInsertedBracketPairs = <String>{
  '""', '()', '[]', '<>', '{}', '”“', '《》', '（）', '【】'
};

/// True when `insert` is a two-character bracket pair appended (no backspaces) onto a non-empty
/// buffer — the case where a host editor auto-inserts the closing bracket, so the whole pair must
/// be sent as a string (sending only the opener lets the host auto-close swallow later input).
/// Mirrors remote_page.dart ~346-356.
bool isAutoInsertedBracketPair(
    String effectiveOldValue, int backspaces, String insert) {
  return effectiveOldValue != '' &&
      backspaces == 0 &&
      _autoInsertedBracketPairs.contains(insert);
}

/// Compose Hangul compatibility jamo (U+3131–U+3163) sequences into
/// precomposed syllables (U+AC00–U+D7A3).
///
/// The Android IME sometimes appends raw jamo instead of composing in place —
/// notably for the first syllable, where the '1' sentinel filling the hidden
/// text field confuses the IME's language context, so "안" arrives as "ㅇㅏㄴ".
/// Without composing here, the diff below would forward the raw jamo and the
/// host would show "ㅇㅏㄴ녕하세요".
///
/// Already-composed syllables, non-jamo characters, and lone jamo that cannot
/// form a syllable pass through unchanged. Greedy left-to-right composition
/// with the standard "a final consonant becomes the initial of the next
/// syllable when a vowel follows" rule; combined with the caller's
/// backspace-and-retype diff, any transient mis-composition self-corrects on
/// the next keystroke.
String composeHangulJamo(String s) {
  final out = StringBuffer();
  int? c; // choseong index 0-18
  int? v; // jungseong index 0-20
  int? t; // jongseong index 1-27 (null = none)

  void emitSyllable(int cc, int vv, int tt) {
    out.writeCharCode(0xAC00 + (cc * 21 + vv) * 28 + tt);
  }

  void flush() {
    if (c != null && v != null) {
      emitSyllable(c!, v!, t ?? 0);
    } else if (c != null) {
      out.writeCharCode(_choseongCompat[c!]);
    } else if (v != null) {
      out.writeCharCode(0x314F + v!);
    }
    // t is only ever set when c and v are set, so there is no lone-t case.
    c = v = t = null;
  }

  for (final rune in s.runes) {
    final cj = _choseongIndex(rune);
    final vj = _jungseongIndex(rune);
    final tj = _jongseongIndex(rune);

    if (vj != null) {
      if (c != null && v == null) {
        v = vj;
      } else if (c != null && v != null && t == null) {
        final compound = _compoundVowel(v!, vj);
        if (compound != null) {
          v = compound;
        } else {
          flush();
          out.writeCharCode(rune);
        }
      } else if (c != null && v != null && t != null) {
        // C+V+T followed by a vowel: the final consonant shifts to become
        // the initial of the next syllable; a compound final splits.
        final split = _splitJongseong(t!);
        if (split != null) {
          emitSyllable(c!, v!, split.$1);
          c = _jongseongToChoseong(split.$2) ?? _choseongFallback(split.$2);
        } else {
          emitSyllable(c!, v!, 0);
          c = _jongseongToChoseong(t!) ?? _choseongFallback(t!);
        }
        v = vj;
        t = null;
      } else {
        flush();
        out.writeCharCode(rune);
      }
    } else if (cj != null || tj != null) {
      if (c == null && v == null) {
        if (cj != null) {
          c = cj;
        } else {
          out.writeCharCode(rune); // e.g. ㄳ cannot start a syllable
        }
      } else if (c != null && v == null) {
        // Two consonants in a row: the pending choseong cannot take a
        // second consonant, so flush it. (A real double like ㄲ arrives as
        // the single codepoint U+3132, not as two jamo.)
        flush();
        if (cj != null) {
          c = cj;
        } else {
          out.writeCharCode(rune);
        }
      } else if (c != null && v != null && t == null) {
        // Greedy jongseong: assume the consonant closes the syllable.
        // If the user keeps typing, the backspace-and-retype diff corrects
        // any mis-guess (e.g. 가+ㄴ+ㅏ converges to 가나, not 간아).
        if (tj != null) {
          t = tj;
        } else {
          // ㄸ/ㅃ/ㅉ have no jongseong form: flush, start a new syllable.
          flush();
          c = cj;
        }
      } else if (c != null && v != null && t != null) {
        final compound = _compoundJongseong(t!, rune);
        if (compound != null) {
          t = compound;
        } else {
          flush();
          if (cj != null) {
            c = cj;
          } else {
            out.writeCharCode(rune);
          }
        }
      } else {
        flush();
        out.writeCharCode(rune);
      }
    } else {
      // Not a jamo (precomposed syllable, space, latin, ...): flush, copy.
      flush();
      out.writeCharCode(rune);
    }
  }
  flush();
  return out.toString();
}

// Compatibility jamo -> choseong index (0-18), or null.
int? _choseongIndex(int rune) {
  switch (rune) {
    case 0x3131: return 0; // ㄱ
    case 0x3132: return 1; // ㄲ
    case 0x3134: return 2; // ㄴ
    case 0x3137: return 3; // ㄷ
    case 0x3138: return 4; // ㄸ
    case 0x3139: return 5; // ㄹ
    case 0x3141: return 6; // ㅁ
    case 0x3142: return 7; // ㅂ
    case 0x3143: return 8; // ㅃ
    case 0x3145: return 9; // ㅅ
    case 0x3146: return 10; // ㅆ
    case 0x3147: return 11; // ㅇ
    case 0x3148: return 12; // ㅈ
    case 0x3149: return 13; // ㅉ
    case 0x314A: return 14; // ㅊ
    case 0x314B: return 15; // ㅋ
    case 0x314C: return 16; // ㅌ
    case 0x314D: return 17; // ㅍ
    case 0x314E: return 18; // ㅎ
    default: return null;
  }
}

// Compatibility jamo -> jungseong index (0-20), or null.
int? _jungseongIndex(int rune) {
  if (rune < 0x314F || rune > 0x3163) return null;
  return rune - 0x314F;
}

// Compatibility jamo -> jongseong index (1-27), or null.
// Note: ㄸ (U+3138), ㅃ (U+3143), ㅉ (U+3149) have no jongseong form.
int? _jongseongIndex(int rune) {
  switch (rune) {
    case 0x3131: return 1; // ㄱ
    case 0x3132: return 2; // ㄲ
    case 0x3133: return 3; // ㄳ
    case 0x3134: return 4; // ㄴ
    case 0x3135: return 5; // ㄵ
    case 0x3136: return 6; // ㄶ
    case 0x3137: return 7; // ㄷ
    case 0x3139: return 8; // ㄹ
    case 0x313A: return 9; // ㄺ
    case 0x313B: return 10; // ㄻ
    case 0x313C: return 11; // ㄼ
    case 0x313D: return 12; // ㄽ
    case 0x313E: return 13; // ㄾ
    case 0x313F: return 14; // ㄿ
    case 0x3140: return 15; // ㅀ
    case 0x3141: return 16; // ㅁ
    case 0x3142: return 17; // ㅂ
    case 0x3144: return 18; // ㅄ
    case 0x3145: return 19; // ㅅ
    case 0x3146: return 20; // ㅆ
    case 0x3147: return 21; // ㅇ
    case 0x3148: return 22; // ㅈ
    case 0x314A: return 23; // ㅊ
    case 0x314B: return 24; // ㅋ
    case 0x314C: return 25; // ㅌ
    case 0x314D: return 26; // ㅍ
    case 0x314E: return 27; // ㅎ
    default: return null;
  }
}

// (first vowel index, second vowel index) -> compound vowel index, or null.
int? _compoundVowel(int v1, int v2) {
  if (v1 == 8 && v2 == 0) return 9; // ㅗ+ㅏ=ㅘ
  if (v1 == 8 && v2 == 1) return 10; // ㅗ+ㅐ=ㅙ
  if (v1 == 8 && v2 == 20) return 11; // ㅗ+ㅣ=ㅚ
  if (v1 == 13 && v2 == 4) return 14; // ㅜ+ㅓ=ㅝ
  if (v1 == 13 && v2 == 5) return 15; // ㅜ+ㅔ=ㅞ
  if (v1 == 13 && v2 == 20) return 16; // ㅜ+ㅣ=ㅟ
  if (v1 == 18 && v2 == 20) return 19; // ㅡ+ㅣ=ㅢ
  return null;
}

// (jongseong index, second jamo rune) -> compound jongseong index, or null.
int? _compoundJongseong(int t1, int rune) {
  if (t1 == 1 && rune == 0x3145) return 3; // ㄱ+ㅅ=ㄳ
  if (t1 == 4 && rune == 0x3148) return 5; // ㄴ+ㅈ=ㄵ
  if (t1 == 4 && rune == 0x314E) return 6; // ㄴ+ㅎ=ㄶ
  if (t1 == 8 && rune == 0x3131) return 9; // ㄹ+ㄱ=ㄺ
  if (t1 == 8 && rune == 0x3141) return 10; // ㄹ+ㅁ=ㄻ
  if (t1 == 8 && rune == 0x3142) return 11; // ㄹ+ㅂ=ㄼ
  if (t1 == 8 && rune == 0x3145) return 12; // ㄹ+ㅅ=ㄽ
  if (t1 == 8 && rune == 0x314C) return 13; // ㄹ+ㅌ=ㄾ
  if (t1 == 8 && rune == 0x314D) return 14; // ㄹ+ㅍ=ㄿ
  if (t1 == 8 && rune == 0x314E) return 15; // ㄹ+ㅎ=ㅀ
  if (t1 == 17 && rune == 0x3145) return 18; // ㅂ+ㅅ=ㅄ
  return null;
}

// Split a compound jongseong into (first, second) jongseong indices.
(int, int)? _splitJongseong(int t) {
  switch (t) {
    case 3: return (1, 19); // ㄳ -> ㄱ, ㅅ
    case 5: return (4, 22); // ㄵ -> ㄴ, ㅈ
    case 6: return (4, 27); // ㄶ -> ㄴ, ㅎ
    case 9: return (8, 1); // ㄺ -> ㄹ, ㄱ
    case 10: return (8, 16); // ㄻ -> ㄹ, ㅁ
    case 11: return (8, 17); // ㄼ -> ㄹ, ㅂ
    case 12: return (8, 19); // ㄽ -> ㄹ, ㅅ
    case 13: return (8, 25); // ㄾ -> ㄹ, ㅌ
    case 14: return (8, 26); // ㄿ -> ㄹ, ㅍ
    case 15: return (8, 27); // ㅀ -> ㄹ, ㅎ
    case 18: return (17, 19); // ㅄ -> ㅂ, ㅅ
    default: return null;
  }
}

// Simple jongseong index -> choseong index, or null for compounds.
int? _jongseongToChoseong(int t) {
  switch (t) {
    case 1: return 0; // ㄱ
    case 2: return 1; // ㄲ
    case 4: return 2; // ㄴ
    case 7: return 3; // ㄷ
    case 8: return 5; // ㄹ
    case 16: return 6; // ㅁ
    case 17: return 7; // ㅂ
    case 19: return 9; // ㅅ
    case 20: return 10; // ㅆ
    case 21: return 11; // ㅇ
    case 22: return 12; // ㅈ
    case 23: return 14; // ㅊ
    case 24: return 15; // ㅋ
    case 25: return 16; // ㅌ
    case 26: return 17; // ㅍ
    case 27: return 18; // ㅎ
    default: return null;
  }
}

// Defensive fallback: should be unreachable (split parts are always simple),
// but guarantees composeHangulJamo never throws on unexpected input.
int _choseongFallback(int t) => 11; // ㅇ

const _choseongCompat = <int>[
  0x3131, // ㄱ
  0x3132, // ㄲ
  0x3134, // ㄴ
  0x3137, // ㄷ
  0x3138, // ㄸ
  0x3139, // ㄹ
  0x3141, // ㅁ
  0x3142, // ㅂ
  0x3143, // ㅃ
  0x3145, // ㅅ
  0x3146, // ㅆ
  0x3147, // ㅇ
  0x3148, // ㅈ
  0x3149, // ㅉ
  0x314A, // ㅊ
  0x314B, // ㅋ
  0x314C, // ㅌ
  0x314D, // ㅍ
  0x314E, // ㅎ
];
