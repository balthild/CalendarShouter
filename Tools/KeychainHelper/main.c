// CalendarShouter keychain helper.
//
// Why this exists as a separate binary: macOS pins a keychain item's access to
// the *code identity of the process that created it*. The app's cdhash changes
// on every build (the linker stamps a random LC_UUID), so an item the app
// created asks for permission again after every rebuild. This helper is built
// with `-Wl,-no_uuid`, so it is reproducible: same source, same cdhash, every
// time. The item is therefore owned by a stable identity and stops prompting.
//
// The app spawns this executable; the item's access control names this binary,
// not the app (verified: the keychain records the child's requirement, not the
// parent's).
//
// Because the helper owns the tokens, running it must be proof of identity —
// otherwise any process running as the user could just execute it. Every
// invocation is therefore authenticated:
//
//   * the app passes its own audit token (argv), which the kernel resolves to
//     the real process — a token cannot be forged, and because the check below
//     also binds it to the actual caller, it cannot be forwarded either;
//   * the token's code signature must carry the same certificate this helper is
//     signed with, so only this app can drive it.
//
// Secrets never touch argv (visible in `ps`): a value to store arrives on
// stdin, and a value read is written to stdout.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Exported by libSystem; the header is private, so declare it here.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

enum {
	exitOperational = 1,
	exitUsage = 2,
	exitNotFound = 44,
	exitUnauthenticated = 77,
};

static void describe_status(const char *what, OSStatus status) {
	CFStringRef message = SecCopyErrorMessageString(status, NULL);
	char buffer[256] = { 0 };
	if (message) {
		CFStringGetCString(message, buffer, sizeof(buffer), kCFStringEncodingUTF8);
		CFRelease(message);
	}
	fprintf(stderr, "%s: %d (%s)\n", what, (int)status, buffer);
}

#pragma mark - Authentication

static const char *app_identifier = "com.balthild.CalendarShouter";

// What the caller must satisfy: signed by the same certificate as this helper.
//
// The anchor is the helper's *own* signature, not the app it happens to sit
// next to. Deriving it from the sibling bundle would mean "I trust whatever app
// I am found inside", so copying the helper into another bundle would transfer
// that trust — verified to work, i.e. it was a real bypass. Anchoring on the
// helper's own certificate closes it: a copy still demands a caller signed by
// the same certificate, which an attacker has no way to produce; and re-signing
// the copy changes its cdhash, so the keychain access control stops matching it
// anyway.
//
// The certificate hash is read from the helper's own designated requirement at
// runtime, so nothing about the certificate is baked into this source.
static SecRequirementRef caller_requirement(void) {
	SecCodeRef self = NULL;
	if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess) return NULL;

	SecRequirementRef requirement = NULL;
	SecRequirementRef own = NULL;
	CFStringRef own_string = NULL;
	char buffer[512] = { 0 };

	if (SecCodeCopyDesignatedRequirement(self, kSecCSDefaultFlags, &own) == errSecSuccess) {
		if (SecRequirementCopyString(own, kSecCSDefaultFlags, &own_string) == errSecSuccess) {
			if (CFStringGetCString(own_string, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
				const char *prefix = "certificate root = H\"";
				const char *marker = strstr(buffer, prefix);
				if (marker) {
					marker += strlen(prefix);
					const char *end = strchr(marker, '"');
					if (end && (size_t)(end - marker) == 40) {
						char text[160];
						snprintf(text, sizeof(text), "identifier \"%s\" and certificate root = H\"%.40s\"",
							app_identifier, marker);
						CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
						if (string) {
							SecRequirementCreateWithString(string, kSecCSDefaultFlags, &requirement);
							CFRelease(string);
						}
					}
				}
			}
			CFRelease(own_string);
		}
		CFRelease(own);
	}
	CFRelease(self);
	// An ad-hoc helper has no certificate root in its requirement, so this comes
	// back NULL and authentication fails closed — which is the point.
	return requirement;
}

static int hex_nibble(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static int parse_audit_token(const char *hex, audit_token_t *out) {
	if (strlen(hex) != 64) return 0;
	unsigned int values[8];
	for (int i = 0; i < 8; i++) {
		unsigned int value = 0;
		for (int j = 0; j < 8; j++) {
			int nibble = hex_nibble(hex[i * 8 + j]);
			if (nibble < 0) return 0;
			value = (value << 4) | (unsigned int)nibble;
		}
		values[i] = value;
	}
	audit_token_t token;
	memcpy(&token, values, sizeof(token));
	*out = token;
	return 1;
}

static int authenticate(const char *token_hex) {
	audit_token_t token;
	if (!parse_audit_token(token_hex, &token)) {
		fprintf(stderr, "helper: malformed audit token\n");
		return 0;
	}

	// Bind the token to the process actually talking to us: the caller must be
	// our parent, or the process responsible for us. Without this, a token an
	// attacker managed to obtain could simply be forwarded.
	pid_t caller = (pid_t)token.val[5];
	pid_t parent = getppid();
	pid_t responsible = responsibility_get_pid_responsible_for_pid(getpid());
	if (caller != parent && caller != responsible) {
		fprintf(stderr, "helper: caller %d is neither parent %d nor responsible %d\n", caller, parent, responsible);
		return 0;
	}

	CFDataRef token_data = CFDataCreate(NULL, (const UInt8 *)&token, (CFIndex)sizeof(token));
	const void *keys[] = { kSecGuestAttributeAudit };
	const void *vals[] = { token_data };
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, vals, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	SecCodeRef caller_code = NULL;
	OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &caller_code);
	CFRelease(attributes);
	CFRelease(token_data);
	if (status != errSecSuccess) {
		describe_status("SecCodeCopyGuestWithAttributes", status);
		return 0;
	}

	SecRequirementRef requirement = caller_requirement();
	if (!requirement) {
		fprintf(stderr, "helper: this helper is not signed, so it cannot verify callers\n");
		CFRelease(caller_code);
		return 0;
	}
	status = SecCodeCheckValidity(caller_code, kSecCSDefaultFlags, requirement);
	CFRelease(requirement);
	CFRelease(caller_code);
	if (status != errSecSuccess) {
		describe_status("SecCodeCheckValidity", status);
		return 0;
	}
	return 1;
}

#pragma mark - Keychain

static CFDictionaryRef base_query(const char *service, const char *account) {
	CFStringRef svc = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
	CFStringRef acc = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
	const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount };
	const void *vals[] = { kSecClassGenericPassword, svc, acc };
	CFDictionaryRef query = CFDictionaryCreate(NULL, keys, vals, 3,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(svc);
	CFRelease(acc);
	return query;
}

// Read the stored value from stdin so it never appears in argv.
static char *read_stdin(void) {
	size_t capacity = 4096, length = 0;
	char *buffer = malloc(capacity);
	if (!buffer) return NULL;
	for (;;) {
		if (length + 1 >= capacity) {
			capacity *= 2;
			char *grown = realloc(buffer, capacity);
			if (!grown) { free(buffer); return NULL; }
			buffer = grown;
		}
		size_t got = fread(buffer + length, 1, capacity - length - 1, stdin);
		length += got;
		if (got == 0) break;
	}
	while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) length--;
	buffer[length] = '\0';
	return buffer;
}

// Delete then add, so a write also re-owns an item the app created earlier
// (SecItemUpdate would leave the old access control in place).
static int add_item(const char *service, const char *account, const char *value) {
	CFDictionaryRef query = base_query(service, account);
	SecItemDelete(query);

	CFMutableDictionaryRef attributes = CFDictionaryCreateMutableCopy(NULL, 0, query);
	CFDataRef data = CFDataCreate(NULL, (const UInt8 *)value, (CFIndex)strlen(value));
	CFDictionarySetValue(attributes, kSecValueData, data);
	CFDictionarySetValue(attributes, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlock);

	OSStatus status = SecItemAdd(attributes, NULL);
	CFRelease(attributes);
	CFRelease(data);
	CFRelease(query);
	if (status != errSecSuccess) { describe_status("SecItemAdd", status); return exitOperational; }
	printf("ok\n");
	return 0;
}

static int read_item(const char *service, const char *account) {
	CFDictionaryRef base = base_query(service, account);
	CFMutableDictionaryRef query = CFDictionaryCreateMutableCopy(NULL, 0, base);
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	CFRelease(base);
	if (status == errSecItemNotFound) return exitNotFound;
	if (status != errSecSuccess) { describe_status("SecItemCopyMatching", status); return exitOperational; }
	CFDataRef data = (CFDataRef)result;
	fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), stdout);
	CFRelease(data);
	return 0;
}

static int delete_item(const char *service, const char *account) {
	CFDictionaryRef query = base_query(service, account);
	OSStatus status = SecItemDelete(query);
	CFRelease(query);
	if (status == errSecSuccess || status == errSecItemNotFound) { printf("ok\n"); return 0; }
	describe_status("SecItemDelete", status);
	return exitOperational;
}

int main(int argc, char **argv) {
	if (argc < 5) {
		fprintf(stderr, "usage: %s add|read|delete <service> <account> <audit-token-hex>\n", argv[0]);
		return exitUsage;
	}
	const char *op = argv[1], *service = argv[2], *account = argv[3], *token = argv[4];

	if (!authenticate(token)) {
		fprintf(stderr, "helper: caller did not authenticate\n");
		return exitUnauthenticated;
	}

	if (strcmp(op, "add") == 0) {
		char *value = read_stdin();
		if (!value) { fprintf(stderr, "helper: no value on stdin\n"); return exitUsage; }
		int result = add_item(service, account, value);
		free(value);
		return result;
	}
	if (strcmp(op, "read") == 0) return read_item(service, account);
	if (strcmp(op, "delete") == 0) return delete_item(service, account);
	fprintf(stderr, "helper: unknown op '%s'\n", op);
	return exitUsage;
}
