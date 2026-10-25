/* nn::pl shared fonts: the verified system BFTTF files laid out back to back as in the pl shared memory.
   GetSharedFontAddress points 8 bytes past each file start (after the BFTTF header), as the SDK adds the
   service-provided offset to the shared memory base; the size is the decoded font size. */
#include "runtime.h"
#include "shared_fonts_config.h"
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct{const char *path;uint64_t file_bytes,font_bytes;const char *sha256;} FontRow;
static const FontRow rows[SHARED_FONT_COUNT]={SHARED_FONT_ROWS};
static uint8_t *region;static uint64_t offsets[SHARED_FONT_COUNT];
static pthread_once_t once=PTHREAD_ONCE_INIT;
static void need(int c,const char *m){if(!c)runtime_fail(m);}
static void load(void){
 /* by3: the NSPs do not carry the system fonts; scripts/prepare_runtime.py leaves the rows empty without them. SSBU may ask for
    them too; extract from your own firmware if it does. */
 if(!rows[0].path[0])runtime_fail("the game asked for the system shared fonts: extract them from your own Switch firmware to SSBU_build/extracted/firmware/shared-fonts (scripts/extract_shared_fonts.py) and run scripts/prepare_runtime.py again");
 uint64_t total=0;for(int i=0;i<SHARED_FONT_COUNT;i++)total+=rows[i].file_bytes;
 region=malloc(total);need(region!=NULL,"shared font memory");
 uint64_t at=0;
 for(int i=0;i<SHARED_FONT_COUNT;i++){
  /* TOTK_SHARED_FONTS=<dir>: the same verified files in another directory (iOS: copied into the app's Documents). */
  char path[4096];const char *dir=getenv("TOTK_SHARED_FONTS"),*base=strrchr(rows[i].path,'/');
  const char *fn = base ? base + 1 : rows[i].path;
  FILE *f = NULL;
  if(dir) {
   if (snprintf(path,sizeof path,"%s/%s",dir,fn)<(int)sizeof path) f=fopen(path,"rb");
  }
  if(!f) {
   snprintf(path,sizeof path,"extracted/firmware/shared-fonts/%s",fn);
   f=fopen(path,"rb");
  }
  if(!f) {
   f=fopen(rows[i].path,"rb");
  }
  need(f!=NULL,"open shared font");
  need(fread(region+at,1,rows[i].file_bytes,f)==rows[i].file_bytes&&fgetc(f)==EOF,"shared font size");fclose(f);
  uint8_t d[32];char hex[65];CC_SHA256(region+at,(CC_LONG)rows[i].file_bytes,d);for(int k=0;k<32;k++)snprintf(hex+k*2,3,"%02x",d[k]);
  need(!strcmp(hex,rows[i].sha256),"shared font integrity mismatch");

  /* Decrypt BFTTF payload: big-endian words XORed with key = word0 ^ 0x7f9a0218 */
  uint8_t *file_data = region + at;
  uint32_t magic = ((uint32_t)file_data[0] << 24) |
                   ((uint32_t)file_data[1] << 16) |
                   ((uint32_t)file_data[2] << 8)  |
                   (uint32_t)file_data[3];
  uint32_t key = magic ^ 0x7f9a0218;
  uint8_t k_bytes[4] = {
      (uint8_t)(key >> 24),
      (uint8_t)(key >> 16),
      (uint8_t)(key >> 8),
      (uint8_t)key
  };
  uint32_t host_key;
  memcpy(&host_key, k_bytes, 4);

  uint32_t *words = (uint32_t *)(region + at + 8);
  size_t nwords = (size_t)rows[i].font_bytes / 4;
  for (size_t w = 0; w < nwords; w++) {
      words[w] ^= host_key;
  }
  size_t rem = (size_t)rows[i].font_bytes % 4;
  if (rem) {
      uint8_t *tail = region + at + 8 + (nwords * 4);
      for (size_t b = 0; b < rem; b++) {
          tail[b] ^= k_bytes[b];
      }
  }

  uint8_t *dec = region + at + 8;
  need((dec[0] == 0x00 && dec[1] == 0x01 && dec[2] == 0x00 && dec[3] == 0x00) ||
       (dec[0] == 'O' && dec[1] == 'T' && dec[2] == 'T' && dec[3] == 'O'),
       "decrypted shared font format invalid");
  fprintf(stderr, "[ssbu] shared font %d (%llu bytes) decrypted, magic=%02x%02x%02x%02x\n",
          i, (unsigned long long)rows[i].font_bytes, dec[0], dec[1], dec[2], dec[3]);

  offsets[i]=at+8;at+=rows[i].file_bytes;
 }
 fprintf(stderr,"[ssbu] shared fonts loaded: %d fonts, %llu bytes\n",SHARED_FONT_COUNT,(unsigned long long)total);
}
static int valid(int type){
 fprintf(stderr, "[ssbu-font] valid(type=%d)\n", type);
 if(type<0||type>=SHARED_FONT_COUNT)runtime_fail("invalid shared font type");
 pthread_once(&once,load);
 return type;
}
static int load_state(int type){int v=valid(type); fprintf(stderr, "[ssbu-font] load_state(%d)=1\n", v); return 1;}   /* SharedFontLoadState_Loaded */
static const void *address(int type){int v=valid(type); void *p=region+offsets[v]; fprintf(stderr, "[ssbu-font] address(%d)=%p\n", v, p); return p;}
static size_t size(int type){int v=valid(type); size_t s=(size_t)rows[v].font_bytes; fprintf(stderr, "[ssbu-font] size(%d)=%zu\n", v, s); return s;}
static void request_load(int type){(void)type;}
static unsigned is_vr_mode(void){return 0;}
static void vr_nop(void){}
void *runtime_font_override(const char *name){
 static const struct{const char *name;void *fn;} entries[]={
  {"_ZN2nn2pl21RequestSharedFontLoadENS0_14SharedFontTypeE",request_load},
  {"_ZN2nn2pl22GetSharedFontLoadStateENS0_14SharedFontTypeE",load_state},
  {"_ZN2nn2pl20GetSharedFontAddressENS0_14SharedFontTypeE",address},
  {"_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE",size},
  {"_ZN2nn2pl8IsVrModeEv",is_vr_mode},
  {"_ZN2nn2pl11BeginVrModeEv",vr_nop},
  {"_ZN2nn2pl9EndVrModeEv",vr_nop},
  {"_ZN2nn2pl16IsRunningOnOunceEv",is_vr_mode}};
 for(unsigned i=0;i<sizeof(entries)/sizeof(*entries);i++)if(!strcmp(name,entries[i].name))return entries[i].fn;return NULL;
}
