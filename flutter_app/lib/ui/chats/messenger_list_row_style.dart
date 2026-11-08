import 'dart:ui' show Color;

/// The shared All/Local/Networks row base. Hover and focus stay on each
/// row's InkWell; painting a second hover fill on Material made All look
/// different from the other two lists.
Color messengerListRowColor({required bool selected, required Color accent}) =>
    selected ? accent : const Color(0x00000000);
