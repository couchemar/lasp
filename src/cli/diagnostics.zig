const std = @import("std");
const grammar_loader = @import("../grammar/loader.zig");
const query_parser = @import("../query/parser.zig");

/// The one place the `error: ` prefix is spliced in. Message strings carry none.
const error_prefix = "error: ";

/// Comptime line format: prefix + `fmt` + newline. Rejects a `fmt` that already
/// starts with `error:` so a second prefix cannot be written by accident.
pub fn errorLineFormat(comptime fmt: []const u8) []const u8 {
    comptime if (std.mem.startsWith(u8, fmt, "error:"))
        @compileError("error format must not start with \"error:\": " ++ fmt);
    return error_prefix ++ fmt ++ "\n";
}

/// Prints one prefixed error line to stderr and returns.
pub fn reportError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(errorLineFormat(fmt), args);
}

/// Prints one prefixed error line to stderr and exits with code 1.
pub fn fatalError(comptime fmt: []const u8, args: anytype) noreturn {
    reportError(fmt, args);
    std.process.exit(1);
}
/// Single message for `error.InvalidCharSet` (empty, inverted, non-ASCII endpoint, or bad escape).
const invalid_char_set_message = "[tokens] invalid char set: ranges must have ASCII endpoints and run low-to-high, use \\- for a literal '-' and \\\\ for a literal '\\' (other escapes are not allowed)";

/// Prefix-free message body for an error from `parseGrammar`.
pub fn grammarErrorMessage(err: grammar_loader.GrammarError) []const u8 {
    return switch (err) {
        error.InvalidToml => "invalid TOML syntax in grammar file",
        error.MissingPatterns => "grammar file missing required [[patterns]] section",
        error.EmptyPatternSequence => "pattern has empty sequence",
        error.InvalidCaptureFormat => "invalid capture format, expected $name:IDENTIFIER",
        error.InvalidPositionValue => "invalid position value, expected 'start'",
        error.InvalidWeightValue => "invalid weight value, weights must be non-negative",
        error.InvalidPriorValue => "invalid prior value, prior must be greater than 0.0 and at most 2.0",
        error.InvalidKindName => "invalid kind name, expected IDENTIFIER, NUMBER, or STRING",
        error.InvalidConstraintType => "invalid constraint type",
        error.InvalidConstraintDepth => "invalid constraint depth",
        error.InvalidConstraintField => "invalid constraint field",
        error.InvalidConstraintValues => "invalid constraint values",
        error.DeprecatedField => "deprecated field (exclude/not_preceded_by), use [[patterns.constraints]] instead",
        error.InvalidCommentLineType => "[comments] line must be an array of strings",
        error.InvalidCommentBlockType => "[comments] block_open/block_close must be strings",
        error.UnpairedBlockDelimiter => "[comments] block_open and block_close must both be present or both absent",
        error.CommentPrefixTooLong => "[comments] line prefix too long (max 8 characters)",
        error.TooManyLinePrefixes => "[comments] too many line prefixes (max 16)",
        error.BlockDelimiterTooLong => "[comments] block delimiter too long (max 8 characters)",
        error.InvalidTokenSection => "[tokens] entries must be tables with exactly one recognizer (char_class_run, delimited_span, or literal_set)",
        error.DuplicateKindName => "[tokens] duplicate kind name",
        error.EmptyKindName => "[tokens] kind name must not be empty",
        error.InvalidRecognizer => "[tokens] recognizer must be exactly one of char_class_run, delimited_span, or literal_set",
        error.InvalidCharSet => invalid_char_set_message,
        error.EmptyLiteralSet => "[tokens] literal_set must contain non-empty strings",
        error.InvalidCountTable => "[[patterns.count]] must declare non-empty field, open, close, and separator strings (1-8 bytes)",
        error.TooManyCountTables => "too many [[patterns.count]] tables (max 16)",
        error.DuplicateCountField => "[[patterns.count]] field duplicates a capture or earlier count field",
        error.InvalidCaptureTable => "[[patterns.capture]] must declare a non-empty field and at least one of separator/suffix (1-8 bytes)",
        error.UnknownCaptureField => "[[patterns.capture]] field is not a declared capture",
        error.DuplicateCaptureField => "[[patterns.capture]] duplicate table for the same field",
        error.ParenthesizedCaptureParam => "parenthesized capture parameters are removed; use [[patterns.capture]] tables",
        error.ExtentModeConflict => "[[patterns.extent]] cannot combine terminator with open/close",
        error.ExtentNoMode => "[[patterns.extent]] must declare balanced open/close or a terminator",
        error.ExtentIncompleteBalanced => "[[patterns.extent]] balanced mode requires both open and close",
        error.InvalidExtentField => "[[patterns.extent]] field must be 1-64 bytes",
        error.InvalidExtentDelimiter => "[[patterns.extent]] open/close/terminator must be 1-8 bytes",
        error.DuplicateExtentField => "[[patterns.extent]] field duplicates a capture or count field",
        error.ExtentAtColumnWithoutTerminator => "[[patterns.extent]] at_column requires terminator mode",
        error.InvalidExtentAtColumn => "[[patterns.extent]] at_column must be an integer in 0..65535",
        error.TooManyExtentTables => "at most one [[patterns.extent]] table per pattern",
        error.InvalidExtensionsList => "[language] extensions must be an array of non-empty strings",
        error.OutOfMemory => "out of memory",
        else => "unknown grammar error",
    };
}

/// Prefix-free message body for an error from `query_parser.parse`.
pub fn selectorErrorMessage(err: query_parser.ParseError) []const u8 {
    return switch (err) {
        error.EmptySelector => "empty selector string",
        error.UnclosedBracket => "unclosed bracket in selector",
        error.MissingFieldName => "missing field name in attribute condition",
        error.MissingOperator => "missing or invalid operator in attribute condition",
        error.MissingValue => "missing value in attribute condition",
        error.UnclosedQuote => "unclosed quote in attribute value",
        error.InvalidOperator => "invalid operator, expected '=', '!=', '>', '~=', '^=', or '$='",
        error.ExpectedQuotedValue => "substring operators (~=, ^=, $=) require a quoted string value",
        error.InvalidNumericValue => "invalid numeric value for '>' operator",
        error.UnexpectedCharacter => "unexpected character in selector",
        error.OutOfMemory => "out of memory",
    };
}
