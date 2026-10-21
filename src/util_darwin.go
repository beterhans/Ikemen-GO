//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation

#import <Foundation/Foundation.h>

static void ikemen_disable_press_and_hold(void)
{
    [[NSUserDefaults standardUserDefaults] setObject:@NO forKey:@"ApplePressAndHoldEnabled"];
}
*/
import "C"

import (
	"os/exec"
	"strings"
)

func init() {
	// issue #4049: belt-and-braces only. HIToolbox reads the GLOBAL
	// ApplePressAndHoldEnabled plist and ignores app-domain values for our bundle id,
	// so this alone does not suppress the accent popup. The actual fix is
	// sdl.StopTextInput() in newWindow (src/system_sdl.go).
	C.ikemen_disable_press_and_hold()
}

// osPreferredLanguage reads the first entry of AppleLanguages, e.g. "en-US".
func osPreferredLanguage() string {
	out, err := exec.Command("/usr/bin/defaults", "read", "-g", "AppleLanguages").Output()
	if err != nil {
		return ""
	}
	s := strings.ToLower(string(out))
	first := strings.IndexByte(s, '"')
	if first < 0 {
		return ""
	}
	s = s[first+1:]
	second := strings.IndexByte(s, '"')
	if second < 0 {
		return ""
	}
	return s[:second]
}
