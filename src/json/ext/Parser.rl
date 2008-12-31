/*
 * This code is copyrighted work by Daniel Luz <dev at mernen dot com>.
 * 
 * Distributed under the Ruby and GPLv2 licenses; see COPYING and GPL files
 * for details.
 */
package json.ext;

import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyClass;
import org.jruby.RubyFloat;
import org.jruby.RubyHash;
import org.jruby.RubyInteger;
import org.jruby.RubyModule;
import org.jruby.RubyNumeric;
import org.jruby.RubyObject;
import org.jruby.RubyString;
import org.jruby.anno.JRubyMethod;
import org.jruby.exceptions.RaiseException;
import org.jruby.runtime.Block;
import org.jruby.runtime.ObjectAllocator;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.Visibility;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;

/**
 * The <code>JSON::Ext::Parser</code> class.
 * 
 * <p>This is the JSON parser implemented as a Java class. To use it as the
 * standard parser, set
 *   <pre>JSON.parser = JSON::Ext::Parser</pre>
 * This is performed for you when you <code>include "json/ext"</code>.
 * 
 * <p>This class does not perform the actual parsing, just acts as an interface
 * to Ruby code. When the {@link #parse()} method is invoked, a
 * Parser.ParserSession object is instantiated, which handles the process.
 * 
 * @author mernen
 */
public class Parser extends RubyObject {
    private RubyString vSource;
    private RubyString createId;
    private int maxNesting;
    private boolean allowNaN;

    private static final int DEFAULT_MAX_NESTING = 19;

    private static final String JSON_MINUS_INFINITY = "-Infinity";
    // constant names in the JSON module containing those values
    private static final String CONST_NAN = "NaN";
    private static final String CONST_INFINITY = "Infinity";
    private static final String CONST_MINUS_INFINITY = "MinusInfinity";

    static final ObjectAllocator ALLOCATOR = new ObjectAllocator() {
        public IRubyObject allocate(Ruby runtime, RubyClass klazz) {
            return new Parser(runtime, klazz);
        }
    };

    /**
     * Multiple-value return for internal parser methods.
     * 
     * <p>All the <code>parse<var>Stuff</var></code> methods return instances of
     * <code>ParserResult</code> when successful, or <code>null</code> when
     * there's a problem with the input data.
     */
    static final class ParserResult {
        /**
         * The result of the successful parsing. Should never be
         * <code>null</code>.
         */
        final IRubyObject result;
        /**
         * The point where the parser returned.
         */
        final int p;

        ParserResult(IRubyObject result, int p) {
            this.result = result;
            this.p = p;
        }
    }

    public Parser(Ruby runtime, RubyClass metaClass) {
        super(runtime, metaClass);
    }

    /**
     * <code>Parser.new(source, opts = {})</code>
     * 
     * <p>Creates a new <code>JSON::Ext::Parser</code> instance for the string
     * <code>source</code>.
     * It will be configured by the <code>opts</code> Hash.
     * <code>opts</code> can have the following keys:
     * 
     * <dl>
     * <dt><code>:max_nesting</code>
     * <dd>The maximum depth of nesting allowed in the parsed data
     * structures. Disable depth checking with <code>:max_nesting => false|nil|0</code>,
     * it defaults to 19.
     * 
     * <dt><code>:allow_nan</code>
     * <dd>If set to <code>true</code>, allow <code>NaN</code>,
     * <code>Infinity</code> and <code>-Infinity</code> in defiance of RFC 4627
     * to be parsed by the Parser. This option defaults to <code>false</code>.
     * 
     * <dt><code>:create_additions</code>
     * <dd>If set to <code>false</code>, the Parser doesn't create additions
     * even if a matchin class and <code>create_id</code> was found. This option
     * defaults to <code>true</code>.
     * </dl>
     */
    @JRubyMethod(name = "new", required = 1, optional = 1, meta = true)
    public static IRubyObject newInstance(IRubyObject clazz, IRubyObject[] args, Block block) {
        Parser parser = (Parser)((RubyClass)clazz).allocate();

        parser.callInit(args, block);

        return parser;
    }

    @JRubyMethod(name = "initialize", required = 1, optional = 1,
                 visibility = Visibility.PRIVATE)
    public IRubyObject initialize(IRubyObject[] args) {
        RubyString source = args[0].convertToString();
        int len = source.getByteList().length();

        if (len < 2) {
            throw Utils.newException(getRuntime(), Utils.M_PARSER_ERROR,
                "A JSON text must at least contain two octets!");
        }

        if (args.length > 1) {
            RubyHash opts = args[1].convertToHash();

            IRubyObject maxNesting = Utils.fastGetSymItem(opts, "max_nesting");
            if (maxNesting == null) {
                this.maxNesting = DEFAULT_MAX_NESTING;
            }
            else if (!maxNesting.isTrue()) {
                this.maxNesting = 0;
            }
            else {
                this.maxNesting = RubyNumeric.fix2int(maxNesting);
            }

            IRubyObject allowNaN = Utils.fastGetSymItem(opts, "allow_nan");
            this.allowNaN = allowNaN != null && allowNaN.isTrue();

            IRubyObject createAdditions = Utils.fastGetSymItem(opts, "create_additions");
            if (createAdditions == null || createAdditions.isTrue()) {
                this.createId = getCreateId();
            }
            else {
                this.createId = null;
            }
        }
        else {
            this.maxNesting = DEFAULT_MAX_NESTING;
            this.allowNaN = false;
            this.createId = getCreateId();
        }

        this.vSource = source;
        return this;
    }

    /**
     * <code>Parser#parse()</code>
     * 
     * <p>Parses the current JSON text <code>source</code> and returns the
     * complete data structure as a result.
     */
    @JRubyMethod(name = "parse")
    public IRubyObject parse() {
        return new ParserSession(this).parse();
    }

    /**
     * <code>Parser#source()</code>
     * 
     * <p>Returns a copy of the current <code>source</code> string, that was
     * used to construct this Parser.
     */
    @JRubyMethod(name = "source")
    public IRubyObject source_get() {
        return vSource.dup();
    }

    /**
     * Queries <code>JSON.create_id</code>. Returns <code>null</code> if it is
     * set to <code>nil</code> or <code>false</code>, and a String if not.
     */
    private RubyString getCreateId() {
        IRubyObject v = getRuntime().getModule("JSON").
            callMethod(getRuntime().getCurrentContext(), "create_id");
        return v.isTrue() ? v.convertToString() : null;
    }

    /**
     * A string parsing session.
     * 
     * <p>Once a ParserSession is instantiated, the source string should not
     * change until the parsing is complete. The ParserSession object assumes
     * the source {@link RubyString} is still associated to its original
     * {@link ByteList}, which in turn must still be bound to the same
     * <code>byte[]</code> value (and on the same offset).
     */
    private static class ParserSession {
        private final Parser parser;
        private final Ruby runtime;
        private final ByteList byteList;
        private final byte[] data;
        private int currentNesting = 0;

        // initialization value for all state variables.
        // no idea about the origins of this value, ask Flori ;)
        private static final int EVIL = 0x666;

        private ParserSession(Parser parser) {
            this.parser = parser;
            runtime = parser.getRuntime();
            byteList = parser.vSource.getByteList();
            data = byteList.unsafeBytes();
        }

        private RaiseException unexpectedToken(int start, int end) {
            RubyString msg =
                runtime.newString("unexpected token at '")
                       .cat(data, byteList.begin() + start, end - start)
                       .cat((byte)'\'');
            return Utils.newException(runtime, Utils.M_PARSER_ERROR, msg);
        }

        %%{
            machine JSON_common;

            cr                  = '\n';
            cr_neg              = [^\n];
            ws                  = [ \t\r\n];
            c_comment           = '/*' ( any* - (any* '*/' any* ) ) '*/';
            cpp_comment         = '//' cr_neg* cr;
            comment             = c_comment | cpp_comment;
            ignore              = ws | comment;
            name_separator      = ':';
            value_separator     = ',';
            Vnull               = 'null';
            Vfalse              = 'false';
            Vtrue               = 'true';
            VNaN                = 'NaN';
            VInfinity           = 'Infinity';
            VMinusInfinity      = '-Infinity';
            begin_value         = [nft"\-[{NI] | digit;
            begin_object        = '{';
            end_object          = '}';
            begin_array         = '[';
            end_array           = ']';
            begin_string        = '"';
            begin_name          = begin_string;
            begin_number        = digit | '-';
        }%%

        %%{
            machine JSON_value;
            include JSON_common;

            write data;

            action parse_null {
                result = runtime.getNil();
            }
            action parse_false {
                result = runtime.getFalse();
            }
            action parse_true {
                result = runtime.getTrue();
            }
            action parse_nan {
                if (parser.allowNaN) {
                    result = getConstant(CONST_NAN);
                }
                else {
                    throw unexpectedToken(p - 2, pe);
                }
            }
            action parse_infinity {
                if (parser.allowNaN) {
                    result = getConstant(CONST_INFINITY);
                }
                else {
                    throw unexpectedToken(p - 7, pe);
                }
            }
            action parse_number {
                if (pe > fpc + 9 &&
                    byteList.subSequence(fpc, fpc + 9).toString().equals(JSON_MINUS_INFINITY)) {

                    if (parser.allowNaN) {
                        result = getConstant(CONST_MINUS_INFINITY);
                        fexec p + 10;
                        fhold;
                        fbreak;
                    }
                    else {
                        throw unexpectedToken(p, pe);
                    }
                }
                ParserResult res = parseFloat(fpc, pe);
                if (res != null) {
                    result = res.result;
                    fexec res.p;
                }
                res = parseInteger(fpc, pe);
                if (res != null) {
                    result = res.result;
                    fexec res.p;
                }
                fhold;
                fbreak;
            }
            action parse_string {
                ParserResult res = parseString(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result = res.result;
                    fexec res.p;
                }
            }
            action parse_array {
                currentNesting++;
                ParserResult res = parseArray(fpc, pe);
                currentNesting--;
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result = res.result;
                    fexec res.p;
                }
            }
            action parse_object {
                currentNesting++;
                ParserResult res = parseObject(fpc, pe);
                currentNesting--;
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result = res.result;
                    fexec res.p;
                }
            }
            action exit {
                fhold;
                fbreak;
            }

            main := ( Vnull @parse_null |
                      Vfalse @parse_false |
                      Vtrue @parse_true |
                      VNaN @parse_nan |
                      VInfinity @parse_infinity |
                      begin_number >parse_number |
                      begin_string >parse_string |
                      begin_array >parse_array |
                      begin_object >parse_object
                    ) %*exit;
        }%%

        ParserResult parseValue(int p, int pe) {
            int cs = EVIL;
            IRubyObject result = null;

            %% write init;
            %% write exec;

            if (cs >= JSON_value_first_final && result != null) {
                return new ParserResult(result, p);
            }
            else {
                return null;
            }
        }

        %%{
            machine JSON_integer;

            write data;

            action exit {
                fhold;
                fbreak;
            }

            main := '-'? ( '0' | [1-9][0-9]* ) ( ^[0-9] @exit );
        }%%

        ParserResult parseInteger(int p, int pe) {
            int cs = EVIL;

            %% write init;
            int memo = p;
            %% write exec;

            if (cs < JSON_integer_first_final) {
                return null;
            }

            ByteList num = (ByteList)byteList.subSequence(memo, p);
            // note: this is actually a shared string, but since it is temporary and
            //       read-only, it doesn't really matter
            RubyString expr = RubyString.newStringLight(runtime, num);
            RubyInteger number = RubyNumeric.str2inum(runtime, expr, 10, true);
            return new ParserResult(number, p + 1);
        }

        %%{
            machine JSON_float;
            include JSON_common;

            write data;

            action exit {
                fhold;
                fbreak;
            }

            main := '-'?
                    ( ( ( '0' | [1-9][0-9]* ) '.' [0-9]+ ( [Ee] [+\-]?[0-9]+ )? )
                    | ( ( '0' | [1-9][0-9]* ) ( [Ee] [+\-]? [0-9]+ ) ) )
                    ( ^[0-9Ee.\-] @exit );
        }%%

        ParserResult parseFloat(int p, int pe) {
            int cs = EVIL;

            %% write init;
            int memo = p;
            %% write exec;

            if (cs < JSON_float_first_final) {
                return null;
            }

            ByteList num = (ByteList)byteList.subSequence(memo, p);
            // note: this is actually a shared string, but since it is temporary and
            //       read-only, it doesn't really matter
            RubyString expr = RubyString.newStringLight(runtime, num);
            RubyFloat number = RubyNumeric.str2fnum(runtime, expr, true);
            return new ParserResult(number, p + 1);
        }

        %%{
            machine JSON_string;
            include JSON_common;

            write data;

            action parse_string {
                result = stringUnescape(memo + 1, p);
                if (result == null) {
                    fhold;
                    fbreak;
                }
                else {
                    fexec p + 1;
                }
            }

            action exit {
                fhold;
                fbreak;
            }

            main := '"'
                    ( ( ^(["\\]|0..0x1f)
                      | '\\'["\\/bfnrt]
                      | '\\u'[0-9a-fA-F]{4}
                      | '\\'^(["\\/bfnrtu]|0..0x1f)
                      )* %parse_string
                    ) '"' @exit;
        }%%

        ParserResult parseString(int p, int pe) {
            int cs = EVIL;
            RubyString result = null;

            %% write init;
            int memo = p;
            %% write exec;

            if (cs >= JSON_string_first_final && result != null) {
                return new ParserResult(result, p + 1);
            }
            else {
                return null;
            }
        }

        private RubyString stringUnescape(int start, int end) {
            int len = end - start;
            RubyString result = runtime.newString(new ByteList(len));

            int relStart = start - byteList.begin();
            int relEnd = end - byteList.begin();

            int surrogateStart = -1;
            char surrogate = 0;

            for (int i = relStart; i < relEnd; ) {
                char c = byteList.charAt(i);
                if (c == '\\') {
                    i++;
                    if (i >= relEnd) {
                        return null;
                    }
                    c = byteList.charAt(i);
                    if (surrogateStart != -1 && c != 'u') {
                        throw Utils.newException(runtime, Utils.M_PARSER_ERROR,
                            "partial character in source, but hit end near ",
                            (ByteList)byteList.subSequence(surrogateStart, relEnd));
                    }
                    switch (c) {
                        case '"':
                        case '\\':
                            result.cat((byte)c);
                            i++;
                            break;
                        case 'b':
                            result.cat((byte)'\b');
                            i++;
                            break;
                        case 'f':
                            result.cat((byte)'\f');
                            i++;
                            break;
                        case 'n':
                            result.cat((byte)'\n');
                            i++;
                            break;
                        case 'r':
                            result.cat((byte)'\r');
                            i++;
                            break;
                        case 't':
                            result.cat((byte)'\t');
                            i++;
                            break;
                        case 'u':
                            // XXX append the UTF-8 representation of characters for now;
                            //     once JRuby supports Ruby 1.9, this might change
                            i++;
                            if (i > relEnd - 4) {
                                return null;
                            }
                            else {
                                String digits = byteList.subSequence(i, i + 4).toString();
                                int code = Integer.parseInt(digits, 16);
                                if (surrogateStart != -1) {
                                    if (Character.isLowSurrogate((char)code)) {
                                        int fullCode = Character.toCodePoint(surrogate, (char)code);
                                        result.cat(getUTF8Bytes(fullCode | 0L));
                                        surrogateStart = -1;
                                        surrogate = 0;
                                    }
                                    else {
                                        throw Utils.newException(runtime, Utils.M_PARSER_ERROR,
                                            "partial character in source, but hit end near ",
                                            (ByteList)byteList.subSequence(surrogateStart, relEnd));
                                    }
                                }
                                else if (Character.isHighSurrogate((char)code)) {
                                    surrogateStart = i - 2;
                                    surrogate = (char)code;
                                }
                                else {
                                    result.cat(getUTF8Bytes(code));
                                }
                                i += 4;
                            }
                            break;
                        default:
                            result.cat((byte)c);
                            i++;
                    }
                }
                else if (surrogateStart != -1) {
                    throw Utils.newException(runtime, Utils.M_PARSER_ERROR,
                        "partial character in source, but hit end near ",
                        (ByteList)byteList.subSequence(surrogateStart, relEnd));
                }
                else {
                    int j = i;
                    while (j < relEnd && byteList.charAt(j) != '\\') j++;
                    result.cat(data, byteList.begin() + i, j - i);
                    i = j;
                }
            }
            if (surrogateStart != -1) {
                throw Utils.newException(runtime, Utils.M_PARSER_ERROR,
                    "partial character in source, but hit end near ",
                    (ByteList)byteList.subSequence(surrogateStart, relEnd));
            }
            return result;
        }

        /**
         * Converts a code point into an UTF-8 representation.
         * @param code The character code point
         * @return An array containing the UTF-8 bytes for the given code point
         */
        private static byte[] getUTF8Bytes(long code) {
            if (code < 0x80) {
                return new byte[] {(byte)code};
            }
            if (code < 0x800) {
                return new byte[] {(byte)(0xc0 | code >>> 6),
                                   (byte)(0x80 | code & 0x3f)};
            }
            if (code < 0x10000) {
                return new byte[] {(byte)(0xe0 | code >>> 12),
                                   (byte)(0x80 | code >>> 6 & 0x3f),
                                   (byte)(0x80 | code & 0x3f)};
            }
            return new byte[] {(byte)(0xf0 | code >>> 18),
                               (byte)(0x80 | code >>> 12 & 0x3f),
                               (byte)(0x80 | code >>> 6 & 0x3f),
                               (byte)(0x80 | code & 0x3f)};
        }

        %%{
            machine JSON_array;
            include JSON_common;

            write data;

            action parse_value {
                ParserResult res = parseValue(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result.append(res.result);
                    fexec res.p;
                }
            }

            action exit {
                fhold;
                fbreak;
            }

            next_element = value_separator ignore* begin_value >parse_value;

            main := begin_array
                    ignore*
                    ( ( begin_value >parse_value
                        ignore* )
                      ( ignore*
                        next_element
                        ignore* )* )?
                    ignore*
                    end_array @exit;
        }%%

        ParserResult parseArray(int p, int pe) {
            int cs = EVIL;

            if (parser.maxNesting > 0 && currentNesting > parser.maxNesting) {
                throw Utils.newException(runtime, Utils.M_NESTING_ERROR,
                    "nesting of " + currentNesting + " is too deep");
            }

            RubyArray result = runtime.newArray();

            %% write init;
            %% write exec;

            if (cs >= JSON_array_first_final) {
                return new ParserResult(result, p + 1);
            }
            else {
                throw unexpectedToken(p, pe);
            }
        }

        %%{
            machine JSON_object;
            include JSON_common;

            write data;

            action parse_value {
                ParserResult res = parseValue(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result.op_aset(lastName, res.result);
                    fexec res.p;
                }
            }

            action parse_name {
                ParserResult res = parseString(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    lastName = (RubyString)res.result;
                    fexec res.p;
                }
            }

            action exit {
                fhold;
                fbreak;
            }

            a_pair = ignore*
                     begin_name >parse_name
                     ignore* name_separator ignore*
                     begin_value >parse_value;

            main := begin_object
                    (a_pair (ignore* value_separator a_pair)*)?
                    ignore* end_object @exit;
        }%%

        ParserResult parseObject(int p, int pe) {
            int cs = EVIL;
            RubyString lastName = null;

            if (parser.maxNesting > 0 && currentNesting > parser.maxNesting) {
                throw Utils.newException(runtime, Utils.M_NESTING_ERROR,
                    "nesting of " + currentNesting + " is too deep");
            }

            RubyHash result = RubyHash.newHash(runtime);

            %% write init;
            %% write exec;

            if (cs < JSON_object_first_final) {
                return null;
            }

            IRubyObject returnedResult = result;

            // attempt to de-serialize object
            if (parser.createId != null) {
                IRubyObject vKlassName = result.op_aref(runtime.getCurrentContext(), parser.createId);
                if (!vKlassName.isNil()) {
                    String klassName = vKlassName.asJavaString();
                    RubyModule klass;
                    try {
                        klass = runtime.getClassFromPath(klassName);
                    }
                    catch (RaiseException e) {
                        if (runtime.getClass("NameError").isInstance(e.getException())) {
                            // invalid class path, but we're supposed to throw ArgumentError
                            throw runtime.newArgumentError("undefined class/module " + klassName);
                        }
                        else {
                            // some other exception; let it propagate
                            throw e;
                        }
                    }
                    ThreadContext context = runtime.getCurrentContext();
                    if (klass.respondsTo("json_creatable?") &&
                        klass.callMethod(context, "json_creatable?").isTrue()) {

                        returnedResult = klass.callMethod(context, "json_create", result);
                    }
                }
            }
            return new ParserResult(returnedResult, p + 1);
        }

        %%{
            machine JSON;
            include JSON_common;

            write data;

            action parse_object {
                currentNesting = 1;
                ParserResult res = parseObject(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result = res.result;
                    fexec res.p;
                }
            }

            action parse_array {
                currentNesting = 1;
                ParserResult res = parseArray(fpc, pe);
                if (res == null) {
                    fhold;
                    fbreak;
                }
                else {
                    result = res.result;
                    fexec res.p;
                }
            }

            main := ignore*
                    ( begin_object >parse_object
                    | begin_array >parse_array )
                    ignore*;
        }%%

        public IRubyObject parse() {
            int cs = EVIL;
            int p, pe;
            IRubyObject result = null;

            %% write init;
            p = byteList.begin();
            pe = p + byteList.length();
            %% write exec;

            if (cs >= JSON_first_final && p == pe) {
                return result;
            }
            else {
                throw unexpectedToken(p, pe);
            }
        }

        /**
         * Retrieves a constant directly descended from the <code>JSON</code> module.
         * @param name The constant name
         */
        private IRubyObject getConstant(String name) {
            return runtime.getModule("JSON").getConstant(name);
        }
    }
}
