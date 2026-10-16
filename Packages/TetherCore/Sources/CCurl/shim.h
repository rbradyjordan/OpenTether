#include <curl/curl.h>

/* Swift cannot call the variadic curl_easy_setopt; these fix the argument type. */
static inline long tether_curl_setopt_long(CURL *h, CURLoption opt, long v) { return curl_easy_setopt(h, opt, v); }
static inline long tether_curl_setopt_string(CURL *h, CURLoption opt, const char *v) { return curl_easy_setopt(h, opt, v); }
static inline long tether_curl_setopt_pointer(CURL *h, CURLoption opt, void *v) { return curl_easy_setopt(h, opt, v); }
static inline long tether_curl_setopt_readfn(CURL *h, CURLoption opt, curl_read_callback v) { return curl_easy_setopt(h, opt, v); }
static inline long tether_curl_setopt_xferfn(CURL *h, CURLoption opt, curl_xferinfo_callback v) { return curl_easy_setopt(h, opt, v); }
static inline long tether_curl_response_code(CURL *h) { long code = 0; curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code); return code; }
