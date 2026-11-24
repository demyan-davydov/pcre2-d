/// Minimal C declarations of the used subset of pcre2.h (16-bit library, PCRE2_CODE_UNIT_WIDTH 16).
module pcre2.c_api;

extern (C) @nogc nothrow:

alias PCRE2_SIZE = size_t;
alias PCRE2_SPTR16 = const(wchar)*;

struct pcre2_code_16;
struct pcre2_match_data_16;
struct pcre2_match_context_16;
struct pcre2_general_context_16;
struct pcre2_compile_context_16;
struct pcre2_jit_stack_16;
alias pcre2_jit_callback_16 = pcre2_jit_stack_16* function(void*);

enum PCRE2_ZERO_TERMINATED = ~cast(size_t) 0;
enum PCRE2_UNSET = ~cast(size_t) 0;

// compile / match options
enum uint PCRE2_ANCHORED = 0x80000000u;
enum uint PCRE2_NO_UTF_CHECK = 0x40000000u;
enum uint PCRE2_CASELESS = 0x00000008u;
enum uint PCRE2_DOLLAR_ENDONLY = 0x00000010u;
enum uint PCRE2_DOTALL = 0x00000020u;
enum uint PCRE2_MULTILINE = 0x00000400u;
enum uint PCRE2_UTF = 0x00080000u;
enum uint PCRE2_NOTEMPTY_ATSTART = 0x00000008u;
enum uint PCRE2_JIT_COMPLETE = 0x00000001u;

// pcre2_pattern_info / pcre2_config
enum uint PCRE2_INFO_CAPTURECOUNT = 4;
enum uint PCRE2_INFO_NAMECOUNT = 17;
enum uint PCRE2_INFO_NAMEENTRYSIZE = 18;
enum uint PCRE2_INFO_NAMETABLE = 19;
enum uint PCRE2_CONFIG_JIT = 1;
enum uint PCRE2_CONFIG_NEWLINE = 5;
enum uint PCRE2_CONFIG_UNICODE = 9;

// error codes
enum int PCRE2_ERROR_NOMATCH = -1;
enum int PCRE2_ERROR_UTF16_ERR1 = -24;
enum int PCRE2_ERROR_UTF16_ERR2 = -25;
enum int PCRE2_ERROR_UTF16_ERR3 = -26;
enum int PCRE2_ERROR_BADUTFOFFSET = -36;
enum int PCRE2_ERROR_JIT_BADOPTION = -45;
enum int PCRE2_ERROR_JIT_STACKLIMIT = -46;
enum int PCRE2_ERROR_MATCHLIMIT = -47;
enum int PCRE2_ERROR_NOMEMORY = -48;
enum int PCRE2_ERROR_DEPTHLIMIT = -53;
enum int PCRE2_ERROR_HEAPLIMIT = -63;

pcre2_code_16* pcre2_compile_16(PCRE2_SPTR16 pattern, PCRE2_SIZE length, uint options,
    int* errorcode, PCRE2_SIZE* erroroffset, pcre2_compile_context_16* ccontext);
void pcre2_code_free_16(pcre2_code_16* code);
int pcre2_pattern_info_16(const(pcre2_code_16)* code, uint what, void* where);
int pcre2_config_16(uint what, void* where);
int pcre2_get_error_message_16(int errorcode, wchar* buffer, PCRE2_SIZE bufflen);

pcre2_match_data_16* pcre2_match_data_create_from_pattern_16(const(pcre2_code_16)* code,
    pcre2_general_context_16* gcontext);
void pcre2_match_data_free_16(pcre2_match_data_16* md);
PCRE2_SIZE* pcre2_get_ovector_pointer_16(pcre2_match_data_16* md);
uint pcre2_get_ovector_count_16(pcre2_match_data_16* md);

int pcre2_match_16(const(pcre2_code_16)* code, PCRE2_SPTR16 subject, PCRE2_SIZE length,
    PCRE2_SIZE startoffset, uint options, pcre2_match_data_16* md, pcre2_match_context_16* mcontext);

pcre2_match_context_16* pcre2_match_context_create_16(pcre2_general_context_16* gcontext);
void pcre2_match_context_free_16(pcre2_match_context_16* mcontext);
int pcre2_set_match_limit_16(pcre2_match_context_16* mcontext, uint value);
int pcre2_set_depth_limit_16(pcre2_match_context_16* mcontext, uint value);
int pcre2_set_heap_limit_16(pcre2_match_context_16* mcontext, uint value);

int pcre2_jit_compile_16(pcre2_code_16* code, uint options);
int pcre2_jit_match_16(const(pcre2_code_16)* code, PCRE2_SPTR16 subject, PCRE2_SIZE length,
    PCRE2_SIZE startoffset, uint options, pcre2_match_data_16* md, pcre2_match_context_16* mcontext);
pcre2_jit_stack_16* pcre2_jit_stack_create_16(PCRE2_SIZE startsize, PCRE2_SIZE maxsize,
    pcre2_general_context_16* gcontext);
void pcre2_jit_stack_assign_16(pcre2_match_context_16* mcontext, pcre2_jit_callback_16 callback, void* data);
void pcre2_jit_stack_free_16(pcre2_jit_stack_16* stack);
PCRE2_SIZE pcre2_get_startchar_16(pcre2_match_data_16* md);
