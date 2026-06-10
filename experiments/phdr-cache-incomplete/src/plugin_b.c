extern int capture_stack(const char *label);

__attribute__((noinline, used)) static int plugin_b_leaf(const char *label) {
    volatile int rc = capture_stack(label);
    return rc;
}

__attribute__((noinline, used)) static int plugin_b_mid(const char *label) {
    volatile int rc = plugin_b_leaf(label);
    return rc;
}

__attribute__((noinline, used, visibility("default"))) int plugin_b_entry(const char *label) {
    volatile int rc = plugin_b_mid(label);
    return rc;
}
