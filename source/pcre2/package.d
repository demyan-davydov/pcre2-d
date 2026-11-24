/// D binding for PCRE2 (16-bit, UTF-16, @nogc nothrow).
module pcre2;

public import pcre2.regex;
public import pcre2.c_api : pcre2_code_16, pcre2_match_data_16;
