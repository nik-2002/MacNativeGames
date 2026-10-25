/* Super Smash Bros. Ultimate 13.0.4 scaffold.
   The main build ID is deliberately not guessed here: fill it in from the player's own update after
   scripts/extract_code.py has run (scripts/make_expected.py reads it from the NSO header and writes it to the
   generated manifest). No game-code address is defined on purpose: the TotK GAME_ADDR maps do not apply, so any
   leftover use is a compile error. SSBU addresses get named defines here when a patch needs one. */
#pragma once
/* TOTK_* names are inherited from the shared host; here they hold SSBU values. */
#define GAME_SSBU 1
#define TOTK_GAME_VERSION "13.0.4"
#define TOTK_GAME_DIR "v1304"
#define GAME_TITLE_ID 0x01006a800016e000ULL
#define GAME_UPDATE_TITLE_ID 0x01006a800016e800ULL
