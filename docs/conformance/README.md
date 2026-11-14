# vttest screens

One picture and one text dump per screen (the dump starts with the real grid size).

| File | Menu | Grid | First line | Note |
|---|---|---|---|---|
| 001-menu1-s01 | menu1 | 80x24 | ******************************************************************************** |  |
| 002-menu1-s02 | menu1 | 132x24 | ************************************************************************************************************************************ |  |
| 003-menu1-s03 | menu1 | 80x24 | Test of autowrap, mixing control and print characters. |  |
| 004-menu1-s04 | menu1 | 132x24 | Test of autowrap, mixing control and print characters. |  |
| 005-menu1-s05 | menu1 | 80x24 | Test of cursor-control characters inside ESC sequences. |  |
| 006-menu1-s06 | menu1 | 80x24 | Test of leading zeros in ESC sequences. |  |
| 007-menu2-s01 | menu2 | 80x24 | ******************************************************************************** |  |
| 008-menu2-s02 | menu2 | 80x24 | *     *     *     *     *     *     *     *     *     *     *     *     * |  |
| 009-menu2-s03 | menu2 | 132x24 | 12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901 |  |
| 010-menu2-s04 | menu2 | 80x24 | 1234567890123456789012345678901234567890123456789012345678901234567890123456789 |  |
| 011-menu2-s05 | menu2 | 132x24 | 12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901 |  |
| 012-menu2-s06 | menu2 | 80x24 | 1234567890123456789012345678901234567890123456789012345678901234567890123456789 |  |
| 013-menu2-s07 | menu2 | 80x24 | Push <RETURN> |  |
| 014-menu2-s08 | menu2 | 80x24 | Push <RETURN> |  |
| 015-menu2-s09 | menu2 | 80x24 | Push <RETURN> |  |
| 016-menu2-s10 | menu2 | 80x24 | Push <RETURN> |  |
| 017-menu2-s11 | menu2 | 80x24 | This line should be the one above the bottom of the screen. Push <RETURN> |  |
| 018-menu2-s12 | menu2 | 80x24 | This line should be at the top of the screen. Push <RETURN> |  |
| 019-menu2-s13 | menu2 | 80x24 | Graphic rendition test pattern: |  |
| 020-menu2-s14 | menu2 | 80x24 | Graphic rendition test pattern: |  |
| 021-menu2-s15 | menu2 | 80x24 | AAAAA |  |
| - | menu3.1 | 0x0 |  | a setting: the menu came back, no screen |
| - | menu3.2 | 0x0 |  | a setting: the menu came back, no screen |
| - | menu3.3 | 0x0 |  | a setting: the menu came back, no screen |
| 022-menu3.4-s01 | menu3.4 | 80x24 | Menu 3.4: Specify G0 (now US ASCII) | needs a human |
| 023-menu3.5-s01 | menu3.5 | 80x24 | Menu 3.5: Specify G1 (now ISO Latin-1) | needs a human |
| 024-menu3.6-s01 | menu3.6 | 80x24 | Menu 3.6: Specify G2 (now ISO Latin-1) | needs a human |
| 025-menu3.7-s01 | menu3.7 | 80x24 | Menu 3.7: Specify G3 (now ISO Latin-1) | needs a human |
| 026-menu3.8-s01 | menu3.8 | 80x24 | Selected as G0 (with SI)              Selected as G1 (with SO) |  |
| 027-menu3.9-s01 | menu3.9 | 80x24 | These are the G0 and G1 character sets. |  |
| 028-menu3.10-s01 | menu3.10 | 80x24 | Locking shifts, with NRC disabled: |  |
| 029-menu3.11-s01 | menu3.11 | 80x24 | Testing single-shift G2 into GL (SS2) with NRC disabled |  |
| 030-menu3.11-s02 | menu3.11 | 80x24 | Testing single-shift G3 into GL (SS3) with NRC disabled |  |
| 031-menu3.13-s01 | menu3.13 | 80x24 | F1 F2 F3 F4 F5   F6 F7 F8 F9 F10   F11 F12 F13 F14   Help Do   F17 F18 F19 F20 |  |
| 032-menu3.13-s02 | menu3.13 | 80x24 | F1 F2 F3 F4 F5   F6 F7 F8 F9 F10   F11 F12 F13 F14   Help Do   F17 F18 F19 F20 |  |
| 033-menu6.1-s01 | menu6.1 | 80x24 | This is a test of the ANSWERBACK MESSAGE. (To load the A.B.M. |  |
| 034-menu6.2-s01 | menu6.2 | 80x24 | Test of LineFeed/NewLine mode. |  |
| 035-menu6.2-s02 | menu6.2 | 80x24 | Test of LineFeed/NewLine mode. |  |
| 036-menu6.2-s03 | menu6.2 | 80x24 | Test of LineFeed/NewLine mode. |  |
| 037-menu6.3-s01 | menu6.3 | 80x24 | Test of Device Status Report 5 (report terminal status). |  |
| 038-menu6.4-s01 | menu6.4 | 80x24 | Test of Device Attributes report (what are you) |  |
| 039-menu6.5-s01 | menu6.5 | 80x24 | Testing Secondary Device Attributes (Firmware version) |  |
| 040-menu6.6-s01 | menu6.6 | 80x24 | Testing Tertiary Device Attributes (unit ID) |  |
| 041-menu6.7-s01 | menu6.7 | 80x24 | Test of the "Request Terminal Parameters" feature, argument 0. |  |
| 042-menu8-s01 | menu8 | 80x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 043-menu8-s02 | menu8 | 80x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 044-menu8-s03 | menu8 | 80x24 | A******************************************************************************B |  |
| 045-menu8-s04 | menu8 | 80x24 | AB |  |
| 046-menu8-s05 | menu8 | 80x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 047-menu8-s06 | menu8 | 80x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 048-menu8-s07 | menu8 | 80x24 | If your terminal has the ANSI 'Insert Character' function |  |
| 049-menu8-s08 | menu8 | 132x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 050-menu8-s09 | menu8 | 132x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 051-menu8-s10 | menu8 | 132x24 | A**********************************************************************************************************************************B |  |
| 052-menu8-s11 | menu8 | 132x24 | AB |  |
| 053-menu8-s12 | menu8 | 132x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 054-menu8-s13 | menu8 | 132x24 | AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA |  |
| 055-menu8-s14 | menu8 | 132x24 | If your terminal has the ANSI 'Insert Character' function |  |
| - | menu11.1.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.2.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.2.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.2.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.2.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 056-menu11.1.3-s01 | menu11.1.3 | 80x24 | Test 8-bit controls (S7C1T/S8C1T) |  |
| - | menu11.1.4.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.9 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.1.4.10 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 057-menu11.1.5-s01 | menu11.1.5 | 80x24 | You did not specify a font-file with the -f option |  |
| 058-menu11.1.6-s01 | menu11.1.6 | 80x24 | Test Soft Terminal Reset (DECSTR) |  |
| 059-menu11.1.6-s02 | menu11.1.6 | 80x24 | Test Soft Terminal Reset (DECSTR) |  |
| 060-menu11.1.7-s01 | menu11.1.7 | 80x24 | Test User-Defined Keys (DECUDK) | needs a human |
| - | menu11.2.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.1.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.2.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.2.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.3.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.3.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.5.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.6.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.2.6.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.1.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.9 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.2.10 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.9 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.10 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.11 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.12 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.3.13 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.4.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.4.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.4.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.4.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.9 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.10 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.11 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.6.12 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.7.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.7.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.7.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.8.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.3.8.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.1.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.9 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.10 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.11 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.12 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.13 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.2.14 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.5.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.5.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.5.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.6.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.6.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.4.6.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 061-menu11.5.1-s01 | menu11.5.1 | 80x24 | **************************************** |  |
| 062-menu11.5.2-s01 | menu11.5.2 | 80x24 | 1       2       3       4       5       6       7       8       9       10 |  |
| 063-menu11.5.3-s01 | menu11.5.3 | 80x24 | **************************************** |  |
| 064-menu11.5.4-s01 | menu11.5.4 | 80x24 | CHT with param == 1: |  |
| 065-menu11.5.5-s01 | menu11.5.5 | 80x24 | **************************************** |  |
| 066-menu11.5.6-s01 | menu11.5.6 | 80x24 | ***************************************** |  |
| 067-menu11.5.7-s01 | menu11.5.7 | 80x24 | 1. |  |
| 068-menu11.5.8-s01 | menu11.5.8 | 80x24 | 1. |  |
| 069-menu11.5.9-s01 | menu11.5.9 | 80x24 | **************************************** |  |
| - | menu11.6.1 | 0x0 |  | a setting: the menu came back, no screen |
| 070-menu11.6.2-s01 | menu11.6.2 | 80x24 | There are 64 color combinations |  |
| 071-menu11.6.3-s01 | menu11.6.3 | 80x24 | Test SGR-0 color reset |  |
| 072-menu11.6.4-s01 | menu11.6.4 | 80x24 | ********************************************* |  |
| 073-menu11.6.4-s02 | menu11.6.4 | 80x24 | ********************************************* |  |
| 074-menu11.6.5-s01 | menu11.6.5 | 80x24 | ********************************************* |  |
| 075-menu11.6.5-s02 | menu11.6.5 | 80x24 | ********************************************* |  |
| - | menu11.6.6.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.6.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.6.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.6.7.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 076-menu11.6.8-s01 | menu11.6.8 | 80x24 | Push <RETURN> |  |
| 077-menu11.6.8-s02 | menu11.6.8 | 80x24 | Push <RETURN> |  |
| 078-menu11.6.8-s03 | menu11.6.8 | 80x24 | Push <RETURN> |  |
| 079-menu11.6.8-s04 | menu11.6.8 | 80x24 | Push <RETURN> |  |
| 080-menu11.6.8-s05 | menu11.6.8 | 80x24 | Color/Graphic rendition test pattern: |  |
| 081-menu11.6.8-s06 | menu11.6.8 | 80x24 | Color/Graphic rendition test pattern: |  |
| 082-menu11.6.9-s01 | menu11.6.9 | 80x24 | Extended/Graphic rendition test pattern: |  |
| 083-menu11.6.9-s02 | menu11.6.9 | 80x24 | Extended/Graphic rendition test pattern: |  |
| 084-menu11.6.9-s03 | menu11.6.9 | 80x24 | Extended/Graphic rendition test pattern: |  |
| - | menu11.7.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.7.1.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 085-menu11.7.2-s01 | menu11.7.2 | 80x24 | ++++++++++++ |  |
| 086-menu11.7.3-s01 | menu11.7.3 | 80x24 | ******************** |  |
| 087-menu11.7.4-s01 | menu11.7.4 | 80x24 | * |  |
| 088-menu11.7.5-s01 | menu11.7.5 | 80x24 | * |  |
| 089-menu11.7.6-s01 | menu11.7.6 | 80x24 | * |  |
| - | menu11.8.1.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.1.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.1.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.1.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.2.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.2.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.2.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.2.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.2.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 090-menu11.8.3-s01 | menu11.8.3 | 80x24 | Please enter the new window name.  Newer xterms may beep when setting the title. | needs a human |
| - | menu11.8.4.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.4.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.6 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.7 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.5.8 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.6.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.6.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.6.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.6.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.6.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.7.1 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.7.2 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.7.3 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.7.4 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| - | menu11.8.7.5 | 0x0 |  | not walked (depth limit 3): run vttest by hand and choose this path |
| 091-menu11.8.8-s01 | menu11.8.8 | 80x24 | Test of Window modifying. | needs a human |
| 092-menu11.8.9-s01 | menu11.8.9 | 80x24 | Test of Window reporting. |  |
| 093-menu11.8.9-s02 | menu11.8.9 | 80x24 | Test of Window reporting. |  |
