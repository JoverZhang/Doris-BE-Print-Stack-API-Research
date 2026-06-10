extern int capture_stack(const char *label);

__attribute__((noinline, used)) static int plugin_a_leaf(const char *label) {
    volatile int rc = capture_stack(label);
    return rc;
}

__attribute__((noinline, used)) static int plugin_a_mid(const char *label) {
    volatile int rc = plugin_a_leaf(label);
    return rc;
}

__attribute__((noinline, used, visibility("default"))) int plugin_a_entry(const char *label) {
    volatile int rc = plugin_a_mid(label);
    return rc;
}
