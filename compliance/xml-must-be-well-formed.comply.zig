// Content Compliance oracle for an XML 1.0 well-formedness gate.
//
// A well-formed document must render unchanged, and a malformed one must be
// rejected. Each verdict matches `xmllint --noout --nonet` from libxml2
// 2.9.13. Namespaces in XML errors, such as an undeclared prefix, are not
// well-formedness errors: xmllint reports them but still exits 0, so those
// documents are listed as well-formed.
//
// The cases do not cover encodings other than UTF-8, US-ASCII and ISO-8859-1.
// Entity cases cover the replacement text of internal entities, but not
// libxml2's limits on deep or repeated expansion.

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

extern "qip" fn must_reject(ordinal: u64, input_ptr: u32, input_len: u32) i32;

const opml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<?xml-stylesheet type="text/xsl" href="opml.xsl"?>
    \\<opml version="2.0">
    \\  <head>
    \\    <title>Subscriptions</title>
    \\    <dateCreated>Wed, 04 Nov 2026 10:00:00 GMT</dateCreated>
    \\  </head>
    \\  <body>
    \\    <outline text="News">
    \\      <outline text="Caf&#xe9; &amp; Bar" type="rss" xmlUrl="https://example.com/feed?a=1&amp;b=2"/>
    \\    </outline>
    \\  </body>
    \\</opml>
    \\
;

const opml_bare_ampersand =
    \\<opml version="2.0"><body>
    \\<outline text="A & B" xmlUrl="https://example.com/feed"/>
    \\</body></opml>
;

const opml_unclosed =
    \\<opml version="2.0"><body>
    \\<outline text="A" xmlUrl="https://example.com/feed">
    \\</body></opml>
;

const well_formed = [_][]const u8{
    opml,
    "<a/>",
    " <a/> ",
    "<a></a>",
    "<a>text</a>",
    "<?xml version=\"1.0\"?><a/>",
    "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?><a/>",
    "<?xml version='1.1'?><a/>",
    "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>\xe9</a>",
    "<?xml-stylesheet href=\"x\"?><a/>",
    "<?pi?><a/>",
    "<?pi data?><a/>",
    "<?pi:x data?><a/>",
    "<?pidata?><a/>",
    "<!-- c --><a/>",
    "<!----><a/>",
    "<!--->--><a/>",
    "<a><![CDATA[ <x> & ]]></a>",
    "<a>]]</a>",
    "<a>]></a>",
    "<a b=\"1\" c='2'/>",
    "<a b=\"&lt;\"/>",
    "<a b =\"1\" />",
    "<a-b.c_d/>",
    "<a>&amp;&lt;&gt;&apos;&quot;</a>",
    "<a>&#65;&#x41;</a>",
    "<a>\x7f</a>",
    "<a>\t\r\n</a>",
    "<a>\xf0\x9f\x98\x80</a>",
    "\xef\xbb\xbf<a/>",
    "\xef\xbb\xbf<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a/>",
    "<x:a xmlns:x=\"u\"/>",
    "<x:a/>",
    "<a x:b=\"1\"/>",
    "<a xmlns:x=\"u\" xmlns:y=\"u\" x:b=\"1\" y:b=\"2\"/>",
    "<a xmlns:x=\"\"/>",
    "<a xmlns=\"\"/>",
    "<a xmlns=\"u\"><b xmlns=\"\"/></a>",
    "<xmlns:a/>",
    "<a xmlns:xmlns=\"u\"/>",
    "<a xmlns:xml=\"u\"/>",
    "<a xmlns:xml=\"http://www.w3.org/XML/1998/namespace\"/>",
    "<a xml:lang=\"en\"/>",
    "<a xmlns:x=\"http://www.w3.org/XML/1998/namespace\"/>",
    "<a xmlns=\"http://www.w3.org/2000/xmlns/\"/>",
    "<a:b:c xmlns:a=\"u\"/>",
    "<:a/>",
    "<a: xmlns:a=\"u\"/>",
    "<a xmlns:p=\"u\"><p:b/></a><!-- --> ",
    "<a xmlns:p=\"u\"/>",
    "<a><p:b xmlns:p=\"u\"></p:b></a>",
    "<p:a xmlns:p=\"u\"></p:a>",
    "<a xmlns:p=\"u\" p:x=\"1\" x=\"2\"/>",
    "<!DOCTYPE a><a/>",
    "<!DOCTYPE a SYSTEM \"a.dtd\"><a/>",
    "<!DOCTYPE a PUBLIC \"-//X//Y\" \"a.dtd\"><a/>",
    "<!DOCTYPE a []><a/>",
    "<!DOCTYPE a [ ] ><a/>",
    "<!DOCTYPE a [<!ENTITY e \"x\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"x\">]><a b=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e SYSTEM \"e.xml\">]><a>&e;</a>",
    "<!DOCTYPE a SYSTEM \"a.dtd\"><a>&f;</a>",
    "<!DOCTYPE a [<!ENTITY e \"a&b;c\">]><a/>",
    "<!DOCTYPE a [<!ELEMENT a EMPTY>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ANY>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA)>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA)*>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b|c)*>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b,c)>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b|c)+>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ((b|c)*,d?)>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ( b , c )>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b) >]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b)>]><a/>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA #IMPLIED c ID #REQUIRED d (x|y) \"x\" e NOTATION (n) #IMPLIED f CDATA #FIXED \"1\">]><a c=\"1\"/>",
    "<!DOCTYPE a [<!ATTLIST a>]><a/>",
    "<!DOCTYPE a [<!NOTATION n PUBLIC \"p\">]><a/>",
    "<!DOCTYPE a [<!-- c --><?pi x?>]><a/>",
    "<!DOCTYPE a [<!ENTITY a:b \"x\">]><a/>",
    "<a><b><c/></b></a>",
    "<a></a >",
    "<a b=\"&#x3C;\"/>",
    "<a b=\"\t\"/>",
    "<a>\r\n</a>",
    "<\xc3\xa9\xc2\xb7/>",
    "<a\xe2\x80\xbf/>",
    "<!DOCTYPE a [<!ENTITY e \"<\">]><a/>",
    "<!DOCTYPE a [<!ENTITY e \"&e;\">]><a/>",
    "<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&#38;#60;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&#38;#60;\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"&#38;amp;\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"&x;\"><!ENTITY x SYSTEM \"x.xml\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"<b x='&f;'>&f;</b>\"><!ENTITY f '1'>]><a>&e;&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '\"'>]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"<!--x--><?p d?><![CDATA[<]]>\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"x\"><!ATTLIST a k CDATA \"&e;\">]><a/>",
    "<!DOCTYPE a [<!ENTITY e '&f;'><!ENTITY f '&g;'><!ENTITY g 'x'>]><a k='&e;'>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '&#233;&#x10FFFF;'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e 'x'><!ENTITY e '<'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '&#38;f;'><!ENTITY f 'ok'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '&lt;b/>'>]><a>&e;</a>",
    "<!DOCTYPE a SYSTEM \"x.dtd\" [<!ENTITY e \"&f;\">]><a x=\"&e;\"/>",
    "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><!DOCTYPE a [<!ENTITY e '\xe9&#38;#233;'>]><a x='&e;'>&e;</a>",
};

const malformed = [_][]const u8{
    opml_bare_ampersand,
    opml_unclosed,
    "<?xml version=\"2.0\"?><a/>",
    "<?xml version=\"1.0\" standalone=\"maybe\"?><a/>",
    " <?xml version=\"1.0\"?><a/>",
    "<a/><?xml version=\"1.0\"?>",
    "<?XML x?><a/>",
    "<!-- a--b --><a/>",
    "<!-- a ---><a/>",
    "<![CDATA[x]]><a/>",
    "<a>]]></a>",
    "<a><b></a></b>",
    "<a>",
    "</a>",
    "<a/><b/>",
    "text<a/>",
    "<a/>text",
    "",
    "   ",
    "<a b=\"1\" b=\"2\"/>",
    "<a b=1/>",
    "<a b=\"<\"/>",
    "<a b=\"x\"c=\"y\"/>",
    "<a  b = '1' / >",
    "<a/ >",
    "< a/>",
    "<1a/>",
    "<-a/>",
    "<\xe9/>",
    "<a\xb7b/>",
    "<a>&nbsp;</a>",
    "<a>&amp</a>",
    "<a>& </a>",
    "<a>&#0;</a>",
    "<a>&#x1;</a>",
    "<a>&#xD800;</a>",
    "<a>&#x110000;</a>",
    "<a>&#xFFFE;</a>",
    "<a>&#;</a>",
    "<a>&#x;</a>",
    "<a>&#99999999999;</a>",
    "<a>\x01</a>",
    "<a>\xef\xbf\xbe</a>",
    "<a>\xc3</a>",
    "<a>\xc0\x80</a>",
    "<a>\xed\xa0\x80</a>",
    "<a xmlns:x=\"u\" x:b=\"1\" x:b=\"2\"/>",
    "<p:a xmlns:p=\"u\"></q:a>",
    "<!DOCTYPE a PUBLIC \"-//X//Y\"><a/>",
    "<!DOCTYPE a PUBLIC \"{x}\" \"a.dtd\"><a/>",
    "<a/><!DOCTYPE a>",
    "<!DOCTYPE a><!DOCTYPE a><a/>",
    "<!DOCTYPE a [<!ENTITY e SYSTEM \"e.xml\">]><a b=\"&e;\"/>",
    "<!DOCTYPE a [<!NOTATION n SYSTEM \"n\"><!ENTITY e SYSTEM \"e\" NDATA n>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"x\">]><a>&f;</a>",
    "<?xml version=\"1.0\" standalone=\"yes\"?><!DOCTYPE a SYSTEM \"a.dtd\"><a>&f;</a>",
    "<!DOCTYPE a [<!ENTITY e \"%x;\">]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b)>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b,c|d)>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a b>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a ()>]><a/>",
    "<!DOCTYPE a [<!ELEMENT a (b) *>]><a/>",
    "<!DOCTYPE a [<!ATTLIST a b FOO #IMPLIED>]><a/>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA \"<\">]><a/>",
    "<!DOCTYPE a [<!ATTLIST a b CDATA #IMPLIEDc CDATA #IMPLIED>]><a/>",
    "<!DOCTYPE a [<!FOO>]><a/>",
    "<!DOCTYPE a [<!ENTITY e \"x\">]><a b=\"&e\"/>",
    "<a></ a>",
    "<\xcc\x80/>",
    "<!DOCTYPE a [<!ENTITY e \"<\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&e;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&f;\"><!ENTITY f \"&e;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&f;\"><!ENTITY f \"&e;\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"<b x='&e;'/>\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"<b>\">]><a>&e;</b></a>",
    "<!DOCTYPE a [<!ENTITY e \"</b>\">]><a><b>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '<b>'><!ENTITY f '</b>'>]><a>&e;&f;</a>",
    "<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"&#60;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&#60;\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"&#38;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&#38;\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"&f;\">]><a>&e;</a>",
    "<!DOCTYPE a SYSTEM \"x.dtd\" [<!ENTITY e \"&f;\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"&x;\"><!ENTITY x SYSTEM \"x.xml\">]><a x=\"&e;\"/>",
    "<!DOCTYPE a [<!ENTITY e \"<b x='&f;'/>\"><!ENTITY f '<'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"]]>\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"<!--x\">]><a>&e;--></a>",
    "<!DOCTYPE a [<!ENTITY e \"<![CDATA[x\">]><a>&e;]]></a>",
    "<!DOCTYPE a [<!ENTITY e \"<?xml version='1.0'?>\">]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '<!DOCTYPE b>'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e '<b a=\"1\" a=\"2\"/>'>]><a>&e;</a>",
    "<!DOCTYPE a [<!ENTITY e \"<\"><!ATTLIST a k CDATA \"&e;\">]><a/>",
    "<!DOCTYPE a [<!ENTITY e '&#38;e;'>]><a>&e;</a>",
};

export fn comply() i32 {
    inline for (well_formed, 0..) |doc, ordinal| {
        _ = must_render_exactly(ordinal, @intCast(@intFromPtr(doc.ptr)), doc.len, @intCast(@intFromPtr(doc.ptr)), doc.len);
    }
    inline for (malformed, well_formed.len..) |doc, ordinal| {
        _ = must_reject(ordinal, @intCast(@intFromPtr(doc.ptr)), doc.len);
    }
    return well_formed.len + malformed.len;
}
