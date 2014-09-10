// Copyright 2011 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Author: jdtang@google.com (Jonathan Tang)
//
// This is a Ragel state machine re-implementation of the original char_ref.c,
// rewritten to improve efficiency.  To generate the .c file from it,
//
// $ ragel -F1 char_ref.rl
//
// The generated source is also checked into source control so that most people
// hacking on the parser do not need to install ragel.

#include "char_ref.h"

#include <assert.h>
#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>     // Only for debug assertions at present.

#include "error.h"
#include "string_piece.h"
#include "utf8.h"
#include "util.h"

struct GumboInternalParser;

const int kGumboNoChar = -1;

// Table of named character entities, and functions for looking them up.
// http://www.whatwg.org/specs/web-apps/current-work/multipage/named-character-references.html
//
// TODO(jdtang): I'd thought of using more efficient means of this, eg. binary
// searching the table (which can only be done if we know for sure that there's
// enough room in the buffer for our memcmps, otherwise we need to fall back on
// linear search) or compiling the list of named entities to a Ragel state
// machine.  But I'll start with the simple approach and optimize only if
// profiling calls for it.  The one concession to efficiency is to store the
// length of the entity with it, so that we don't need to run a strlen to detect
// potential buffer overflows.
typedef struct {
  const char* name;
  size_t length;
  OneOrTwoCodepoints codepoints;
} NamedCharRef;

#define CHAR_REF(name, codepoint) { name, sizeof(name) - 1, { codepoint, -1 } }
#define MULTI_CHAR_REF(name, code_point, code_point2) \
    { name, sizeof(name) - 1, { code_point, code_point2 } }

// Versions with the semicolon must come before versions without the semicolon,
// otherwise they'll match the invalid name first and record a parse error.
// TODO(jdtang): Replace with a FSM that'll do longest-match-first and probably
// give better performance besides.
static const NamedCharRef kNamedEntities[] = {
  CHAR_REF("AElig", 0xc6),
  CHAR_REF("AMP;", 0x26),
  CHAR_REF("AMP", 0x26),
  CHAR_REF("Aacute;", 0xc1),
  CHAR_REF("Aacute", 0xc1),
  CHAR_REF("Abreve;", 0x0102),
  CHAR_REF("Acirc;", 0xc2),
  CHAR_REF("Acirc", 0xc2),
  CHAR_REF("Acy;", 0x0410),
  CHAR_REF("Afr;", 0x0001d504),
  CHAR_REF("Agrave;", 0xc0),
  CHAR_REF("Agrave", 0xc0),
  CHAR_REF("Alpha;", 0x0391),
  CHAR_REF("Amacr;", 0x0100),
  CHAR_REF("And;", 0x2a53),
  CHAR_REF("Aogon;", 0x0104),
  CHAR_REF("Aopf;", 0x0001d538),
  CHAR_REF("ApplyFunction;", 0x2061),
  CHAR_REF("Aring;", 0xc5),
  CHAR_REF("Aring", 0xc5),
  CHAR_REF("Ascr;", 0x0001d49c),
  CHAR_REF("Assign;", 0x2254),
  CHAR_REF("Atilde;", 0xc3),
  CHAR_REF("Atilde", 0xc3),
  CHAR_REF("Auml;", 0xc4),
  CHAR_REF("Auml", 0xc4),
  CHAR_REF("Backslash;", 0x2216),
  CHAR_REF("Barv;", 0x2ae7),
  CHAR_REF("Barwed;", 0x2306),
  CHAR_REF("Bcy;", 0x0411),
  CHAR_REF("Because;", 0x2235),
  CHAR_REF("Bernoullis;", 0x212c),
  CHAR_REF("Beta;", 0x0392),
  CHAR_REF("Bfr;", 0x0001d505),
  CHAR_REF("Bopf;", 0x0001d539),
  CHAR_REF("Breve;", 0x02d8),
  CHAR_REF("Bscr;", 0x212c),
  CHAR_REF("Bumpeq;", 0x224e),
  CHAR_REF("CHcy;", 0x0427),
  CHAR_REF("COPY;", 0xa9),
  CHAR_REF("COPY", 0xa9),
  CHAR_REF("Cacute;", 0x0106),
  CHAR_REF("Cap;", 0x22d2),
  CHAR_REF("CapitalDifferentialD;", 0x2145),
  CHAR_REF("Cayleys;", 0x212d),
  CHAR_REF("Ccaron;", 0x010c),
  CHAR_REF("Ccedil;", 0xc7),
  CHAR_REF("Ccedil", 0xc7),
  CHAR_REF("Ccirc;", 0x0108),
  CHAR_REF("Cconint;", 0x2230),
  CHAR_REF("Cdot;", 0x010a),
  CHAR_REF("Cedilla;", 0xb8),
  CHAR_REF("CenterDot;", 0xb7),
  CHAR_REF("Cfr;", 0x212d),
  CHAR_REF("Chi;", 0x03a7),
  CHAR_REF("CircleDot;", 0x2299),
  CHAR_REF("CircleMinus;", 0x2296),
  CHAR_REF("CirclePlus;", 0x2295),
  CHAR_REF("CircleTimes;", 0x2297),
  CHAR_REF("ClockwiseContourIntegral;", 0x2232),
  CHAR_REF("CloseCurlyDoubleQuote;", 0x201d),
  CHAR_REF("CloseCurlyQuote;", 0x2019),
  CHAR_REF("Colon;", 0x2237),
  CHAR_REF("Colone;", 0x2a74),
  CHAR_REF("Congruent;", 0x2261),
  CHAR_REF("Conint;", 0x222f),
  CHAR_REF("ContourIntegral;", 0x222e),
  CHAR_REF("Copf;", 0x2102),
  CHAR_REF("Coproduct;", 0x2210),
  CHAR_REF("CounterClockwiseContourIntegral;", 0x2233),
  CHAR_REF("Cross;", 0x2a2f),
  CHAR_REF("Cscr;", 0x0001d49e),
  CHAR_REF("Cup;", 0x22d3),
  CHAR_REF("CupCap;", 0x224d),
  CHAR_REF("DD;", 0x2145),
  CHAR_REF("DDotrahd;", 0x2911),
  CHAR_REF("DJcy;", 0x0402),
  CHAR_REF("DScy;", 0x0405),
  CHAR_REF("DZcy;", 0x040f),
  CHAR_REF("Dagger;", 0x2021),
  CHAR_REF("Darr;", 0x21a1),
  CHAR_REF("Dashv;", 0x2ae4),
  CHAR_REF("Dcaron;", 0x010e),
  CHAR_REF("Dcy;", 0x0414),
  CHAR_REF("Del;", 0x2207),
  CHAR_REF("Delta;", 0x0394),
  CHAR_REF("Dfr;", 0x0001d507),
  CHAR_REF("DiacriticalAcute;", 0xb4),
  CHAR_REF("DiacriticalDot;", 0x02d9),
  CHAR_REF("DiacriticalDoubleAcute;", 0x02dd),
  CHAR_REF("DiacriticalGrave;", 0x60),
  CHAR_REF("DiacriticalTilde;", 0x02dc),
  CHAR_REF("Diamond;", 0x22c4),
  CHAR_REF("DifferentialD;", 0x2146),
  CHAR_REF("Dopf;", 0x0001d53b),
  CHAR_REF("Dot;", 0xa8),
  CHAR_REF("DotDot;", 0x20dc),
  CHAR_REF("DotEqual;", 0x2250),
  CHAR_REF("DoubleContourIntegral;", 0x222f),
  CHAR_REF("DoubleDot;", 0xa8),
  CHAR_REF("DoubleDownArrow;", 0x21d3),
  CHAR_REF("DoubleLeftArrow;", 0x21d0),
  CHAR_REF("DoubleLeftRightArrow;", 0x21d4),
  CHAR_REF("DoubleLeftTee;", 0x2ae4),
  CHAR_REF("DoubleLongLeftArrow;", 0x27f8),
  CHAR_REF("DoubleLongLeftRightArrow;", 0x27fa),
  CHAR_REF("DoubleLongRightArrow;", 0x27f9),
  CHAR_REF("DoubleRightArrow;", 0x21d2),
  CHAR_REF("DoubleRightTee;", 0x22a8),
  CHAR_REF("DoubleUpArrow;", 0x21d1),
  CHAR_REF("DoubleUpDownArrow;", 0x21d5),
  CHAR_REF("DoubleVerticalBar;", 0x2225),
  CHAR_REF("DownArrow;", 0x2193),
  CHAR_REF("DownArrowBar;", 0x2913),
  CHAR_REF("DownArrowUpArrow;", 0x21f5),
  CHAR_REF("DownBreve;", 0x0311),
  CHAR_REF("DownLeftRightVector;", 0x2950),
  CHAR_REF("DownLeftTeeVector;", 0x295e),
  CHAR_REF("DownLeftVector;", 0x21bd),
  CHAR_REF("DownLeftVectorBar;", 0x2956),
  CHAR_REF("DownRightTeeVector;", 0x295f),
  CHAR_REF("DownRightVector;", 0x21c1),
  CHAR_REF("DownRightVectorBar;", 0x2957),
  CHAR_REF("DownTee;", 0x22a4),
  CHAR_REF("DownTeeArrow;", 0x21a7),
  CHAR_REF("Downarrow;", 0x21d3),
  CHAR_REF("Dscr;", 0x0001d49f),
  CHAR_REF("Dstrok;", 0x0110),
  CHAR_REF("ENG;", 0x014a),
  CHAR_REF("ETH;", 0xd0),
  CHAR_REF("ETH", 0xd0),
  CHAR_REF("Eacute;", 0xc9),
  CHAR_REF("Eacute", 0xc9),
  CHAR_REF("Ecaron;", 0x011a),
  CHAR_REF("Ecirc;", 0xca),
  CHAR_REF("Ecirc", 0xca),
  CHAR_REF("Ecy;", 0x042d),
  CHAR_REF("Edot;", 0x0116),
  CHAR_REF("Efr;", 0x0001d508),
  CHAR_REF("Egrave;", 0xc8),
  CHAR_REF("Egrave", 0xc8),
  CHAR_REF("Element;", 0x2208),
  CHAR_REF("Emacr;", 0x0112),
  CHAR_REF("EmptySmallSquare;", 0x25fb),
  CHAR_REF("EmptyVerySmallSquare;", 0x25ab),
  CHAR_REF("Eogon;", 0x0118),
  CHAR_REF("Eopf;", 0x0001d53c),
  CHAR_REF("Epsilon;", 0x0395),
  CHAR_REF("Equal;", 0x2a75),
  CHAR_REF("EqualTilde;", 0x2242),
  CHAR_REF("Equilibrium;", 0x21cc),
  CHAR_REF("Escr;", 0x2130),
  CHAR_REF("Esim;", 0x2a73),
  CHAR_REF("Eta;", 0x0397),
  CHAR_REF("Euml;", 0xcb),
  CHAR_REF("Euml", 0xcb),
  CHAR_REF("Exists;", 0x2203),
  CHAR_REF("ExponentialE;", 0x2147),
  CHAR_REF("Fcy;", 0x0424),
  CHAR_REF("Ffr;", 0x0001d509),
  CHAR_REF("FilledSmallSquare;", 0x25fc),
  CHAR_REF("FilledVerySmallSquare;", 0x25aa),
  CHAR_REF("Fopf;", 0x0001d53d),
  CHAR_REF("ForAll;", 0x2200),
  CHAR_REF("Fouriertrf;", 0x2131),
  CHAR_REF("Fscr;", 0x2131),
  CHAR_REF("GJcy;", 0x0403),
  CHAR_REF("GT;", 0x3e),
  CHAR_REF("GT", 0x3e),
  CHAR_REF("Gamma;", 0x0393),
  CHAR_REF("Gammad;", 0x03dc),
  CHAR_REF("Gbreve;", 0x011e),
  CHAR_REF("Gcedil;", 0x0122),
  CHAR_REF("Gcirc;", 0x011c),
  CHAR_REF("Gcy;", 0x0413),
  CHAR_REF("Gdot;", 0x0120),
  CHAR_REF("Gfr;", 0x0001d50a),
  CHAR_REF("Gg;", 0x22d9),
  CHAR_REF("Gopf;", 0x0001d53e),
  CHAR_REF("GreaterEqual;", 0x2265),
  CHAR_REF("GreaterEqualLess;", 0x22db),
  CHAR_REF("GreaterFullEqual;", 0x2267),
  CHAR_REF("GreaterGreater;", 0x2aa2),
  CHAR_REF("GreaterLess;", 0x2277),
  CHAR_REF("GreaterSlantEqual;", 0x2a7e),
  CHAR_REF("GreaterTilde;", 0x2273),
  CHAR_REF("Gscr;", 0x0001d4a2),
  CHAR_REF("Gt;", 0x226b),
  CHAR_REF("HARDcy;", 0x042a),
  CHAR_REF("Hacek;", 0x02c7),
  CHAR_REF("Hat;", 0x5e),
  CHAR_REF("Hcirc;", 0x0124),
  CHAR_REF("Hfr;", 0x210c),
  CHAR_REF("HilbertSpace;", 0x210b),
  CHAR_REF("Hopf;", 0x210d),
  CHAR_REF("HorizontalLine;", 0x2500),
  CHAR_REF("Hscr;", 0x210b),
  CHAR_REF("Hstrok;", 0x0126),
  CHAR_REF("HumpDownHump;", 0x224e),
  CHAR_REF("HumpEqual;", 0x224f),
  CHAR_REF("IEcy;", 0x0415),
  CHAR_REF("IJlig;", 0x0132),
  CHAR_REF("IOcy;", 0x0401),
  CHAR_REF("Iacute;", 0xcd),
  CHAR_REF("Iacute", 0xcd),
  CHAR_REF("Icirc;", 0xce),
  CHAR_REF("Icirc", 0xce),
  CHAR_REF("Icy;", 0x0418),
  CHAR_REF("Idot;", 0x0130),
  CHAR_REF("Ifr;", 0x2111),
  CHAR_REF("Igrave;", 0xcc),
  CHAR_REF("Igrave", 0xcc),
  CHAR_REF("Im;", 0x2111),
  CHAR_REF("Imacr;", 0x012a),
  CHAR_REF("ImaginaryI;", 0x2148),
  CHAR_REF("Implies;", 0x21d2),
  CHAR_REF("Int;", 0x222c),
  CHAR_REF("Integral;", 0x222b),
  CHAR_REF("Intersection;", 0x22c2),
  CHAR_REF("InvisibleComma;", 0x2063),
  CHAR_REF("InvisibleTimes;", 0x2062),
  CHAR_REF("Iogon;", 0x012e),
  CHAR_REF("Iopf;", 0x0001d540),
  CHAR_REF("Iota;", 0x0399),
  CHAR_REF("Iscr;", 0x2110),
  CHAR_REF("Itilde;", 0x0128),
  CHAR_REF("Iukcy;", 0x0406),
  CHAR_REF("Iuml;", 0xcf),
  CHAR_REF("Iuml", 0xcf),
  CHAR_REF("Jcirc;", 0x0134),
  CHAR_REF("Jcy;", 0x0419),
  CHAR_REF("Jfr;", 0x0001d50d),
  CHAR_REF("Jopf;", 0x0001d541),
  CHAR_REF("Jscr;", 0x0001d4a5),
  CHAR_REF("Jsercy;", 0x0408),
  CHAR_REF("Jukcy;", 0x0404),
  CHAR_REF("KHcy;", 0x0425),
  CHAR_REF("KJcy;", 0x040c),
  CHAR_REF("Kappa;", 0x039a),
  CHAR_REF("Kcedil;", 0x0136),
  CHAR_REF("Kcy;", 0x041a),
  CHAR_REF("Kfr;", 0x0001d50e),
  CHAR_REF("Kopf;", 0x0001d542),
  CHAR_REF("Kscr;", 0x0001d4a6),
  CHAR_REF("LJcy;", 0x0409),
  CHAR_REF("LT;", 0x3c),
  CHAR_REF("LT", 0x3c),
  CHAR_REF("Lacute;", 0x0139),
  CHAR_REF("Lambda;", 0x039b),
  CHAR_REF("Lang;", 0x27ea),
  CHAR_REF("Laplacetrf;", 0x2112),
  CHAR_REF("Larr;", 0x219e),
  CHAR_REF("Lcaron;", 0x013d),
  CHAR_REF("Lcedil;", 0x013b),
  CHAR_REF("Lcy;", 0x041b),
  CHAR_REF("LeftAngleBracket;", 0x27e8),
  CHAR_REF("LeftArrow;", 0x2190),
  CHAR_REF("LeftArrowBar;", 0x21e4),
  CHAR_REF("LeftArrowRightArrow;", 0x21c6),
  CHAR_REF("LeftCeiling;", 0x2308),
  CHAR_REF("LeftDoubleBracket;", 0x27e6),
  CHAR_REF("LeftDownTeeVector;", 0x2961),
  CHAR_REF("LeftDownVector;", 0x21c3),
  CHAR_REF("LeftDownVectorBar;", 0x2959),
  CHAR_REF("LeftFloor;", 0x230a),
  CHAR_REF("LeftRightArrow;", 0x2194),
  CHAR_REF("LeftRightVector;", 0x294e),
  CHAR_REF("LeftTee;", 0x22a3),
  CHAR_REF("LeftTeeArrow;", 0x21a4),
  CHAR_REF("LeftTeeVector;", 0x295a),
  CHAR_REF("LeftTriangle;", 0x22b2),
  CHAR_REF("LeftTriangleBar;", 0x29cf),
  CHAR_REF("LeftTriangleEqual;", 0x22b4),
  CHAR_REF("LeftUpDownVector;", 0x2951),
  CHAR_REF("LeftUpTeeVector;", 0x2960),
  CHAR_REF("LeftUpVector;", 0x21bf),
  CHAR_REF("LeftUpVectorBar;", 0x2958),
  CHAR_REF("LeftVector;", 0x21bc),
  CHAR_REF("LeftVectorBar;", 0x2952),
  CHAR_REF("Leftarrow;", 0x21d0),
  CHAR_REF("Leftrightarrow;", 0x21d4),
  CHAR_REF("LessEqualGreater;", 0x22da),
  CHAR_REF("LessFullEqual;", 0x2266),
  CHAR_REF("LessGreater;", 0x2276),
  CHAR_REF("LessLess;", 0x2aa1),
  CHAR_REF("LessSlantEqual;", 0x2a7d),
  CHAR_REF("LessTilde;", 0x2272),
  CHAR_REF("Lfr;", 0x0001d50f),
  CHAR_REF("Ll;", 0x22d8),
  CHAR_REF("Lleftarrow;", 0x21da),
  CHAR_REF("Lmidot;", 0x013f),
  CHAR_REF("LongLeftArrow;", 0x27f5),
  CHAR_REF("LongLeftRightArrow;", 0x27f7),
  CHAR_REF("LongRightArrow;", 0x27f6),
  CHAR_REF("Longleftarrow;", 0x27f8),
  CHAR_REF("Longleftrightarrow;", 0x27fa),
  CHAR_REF("Longrightarrow;", 0x27f9),
  CHAR_REF("Lopf;", 0x0001d543),
  CHAR_REF("LowerLeftArrow;", 0x2199),
  CHAR_REF("LowerRightArrow;", 0x2198),
  CHAR_REF("Lscr;", 0x2112),
  CHAR_REF("Lsh;", 0x21b0),
  CHAR_REF("Lstrok;", 0x0141),
  CHAR_REF("Lt;", 0x226a),
  CHAR_REF("Map;", 0x2905),
  CHAR_REF("Mcy;", 0x041c),
  CHAR_REF("MediumSpace;", 0x205f),
  CHAR_REF("Mellintrf;", 0x2133),
  CHAR_REF("Mfr;", 0x0001d510),
  CHAR_REF("MinusPlus;", 0x2213),
  CHAR_REF("Mopf;", 0x0001d544),
  CHAR_REF("Mscr;", 0x2133),
  CHAR_REF("Mu;", 0x039c),
  CHAR_REF("NJcy;", 0x040a),
  CHAR_REF("Nacute;", 0x0143),
  CHAR_REF("Ncaron;", 0x0147),
  CHAR_REF("Ncedil;", 0x0145),
  CHAR_REF("Ncy;", 0x041d),
  CHAR_REF("NegativeMediumSpace;", 0x200b),
  CHAR_REF("NegativeThickSpace;", 0x200b),
  CHAR_REF("NegativeThinSpace;", 0x200b),
  CHAR_REF("NegativeVeryThinSpace;", 0x200b),
  CHAR_REF("NestedGreaterGreater;", 0x226b),
  CHAR_REF("NestedLessLess;", 0x226a),
  CHAR_REF("NewLine;", 0x0a),
  CHAR_REF("Nfr;", 0x0001d511),
  CHAR_REF("NoBreak;", 0x2060),
  CHAR_REF("NonBreakingSpace;", 0xa0),
  CHAR_REF("Nopf;", 0x2115),
  CHAR_REF("Not;", 0x2aec),
  CHAR_REF("NotCongruent;", 0x2262),
  CHAR_REF("NotCupCap;", 0x226d),
  CHAR_REF("NotDoubleVerticalBar;", 0x2226),
  CHAR_REF("NotElement;", 0x2209),
  CHAR_REF("NotEqual;", 0x2260),
  MULTI_CHAR_REF("NotEqualTilde;", 0x2242, 0x0338),
  CHAR_REF("NotExists;", 0x2204),
  CHAR_REF("NotGreater;", 0x226f),
  CHAR_REF("NotGreaterEqual;", 0x2271),
  MULTI_CHAR_REF("NotGreaterFullEqual;", 0x2267, 0x0338),
  MULTI_CHAR_REF("NotGreaterGreater;", 0x226b, 0x0338),
  CHAR_REF("NotGreaterLess;", 0x2279),
  MULTI_CHAR_REF("NotGreaterSlantEqual;", 0x2a7e, 0x0338),
  CHAR_REF("NotGreaterTilde;", 0x2275),
  MULTI_CHAR_REF("NotHumpDownHump;", 0x224e, 0x0338),
  MULTI_CHAR_REF("NotHumpEqual;", 0x224f, 0x0338),
  CHAR_REF("NotLeftTriangle;", 0x22ea),
  MULTI_CHAR_REF("NotLeftTriangleBar;", 0x29cf, 0x0338),
  CHAR_REF("NotLeftTriangleEqual;", 0x22ec),
  CHAR_REF("NotLess;", 0x226e),
  CHAR_REF("NotLessEqual;", 0x2270),
  CHAR_REF("NotLessGreater;", 0x2278),
  MULTI_CHAR_REF("NotLessLess;", 0x226a, 0x0338),
  MULTI_CHAR_REF("NotLessSlantEqual;", 0x2a7d, 0x0338),
  CHAR_REF("NotLessTilde;", 0x2274),
  MULTI_CHAR_REF("NotNestedGreaterGreater;", 0x2aa2, 0x0338),
  MULTI_CHAR_REF("NotNestedLessLess;", 0x2aa1, 0x0338),
  CHAR_REF("NotPrecedes;", 0x2280),
  MULTI_CHAR_REF("NotPrecedesEqual;", 0x2aaf, 0x0338),
  CHAR_REF("NotPrecedesSlantEqual;", 0x22e0),
  CHAR_REF("NotReverseElement;", 0x220c),
  CHAR_REF("NotRightTriangle;", 0x22eb),
  MULTI_CHAR_REF("NotRightTriangleBar;", 0x29d0, 0x0338),
  CHAR_REF("NotRightTriangleEqual;", 0x22ed),
  MULTI_CHAR_REF("NotSquareSubset;", 0x228f, 0x0338),
  CHAR_REF("NotSquareSubsetEqual;", 0x22e2),
  MULTI_CHAR_REF("NotSquareSuperset;", 0x2290, 0x0338),
  CHAR_REF("NotSquareSupersetEqual;", 0x22e3),
  MULTI_CHAR_REF("NotSubset;", 0x2282, 0x20d2),
  CHAR_REF("NotSubsetEqual;", 0x2288),
  CHAR_REF("NotSucceeds;", 0x2281),
  MULTI_CHAR_REF("NotSucceedsEqual;", 0x2ab0, 0x0338),
  CHAR_REF("NotSucceedsSlantEqual;", 0x22e1),
  MULTI_CHAR_REF("NotSucceedsTilde;", 0x227f, 0x0338),
  MULTI_CHAR_REF("NotSuperset;", 0x2283, 0x20d2),
  CHAR_REF("NotSupersetEqual;", 0x2289),
  CHAR_REF("NotTilde;", 0x2241),
  CHAR_REF("NotTildeEqual;", 0x2244),
  CHAR_REF("NotTildeFullEqual;", 0x2247),
  CHAR_REF("NotTildeTilde;", 0x2249),
  CHAR_REF("NotVerticalBar;", 0x2224),
  CHAR_REF("Nscr;", 0x0001d4a9),
  CHAR_REF("Ntilde;", 0xd1),
  CHAR_REF("Ntilde", 0xd1),
  CHAR_REF("Nu;", 0x039d),
  CHAR_REF("OElig;", 0x0152),
  CHAR_REF("Oacute;", 0xd3),
  CHAR_REF("Oacute", 0xd3),
  CHAR_REF("Ocirc;", 0xd4),
  CHAR_REF("Ocirc", 0xd4),
  CHAR_REF("Ocy;", 0x041e),
  CHAR_REF("Odblac;", 0x0150),
  CHAR_REF("Ofr;", 0x0001d512),
  CHAR_REF("Ograve;", 0xd2),
  CHAR_REF("Ograve", 0xd2),
  CHAR_REF("Omacr;", 0x014c),
  CHAR_REF("Omega;", 0x03a9),
  CHAR_REF("Omicron;", 0x039f),
  CHAR_REF("Oopf;", 0x0001d546),
  CHAR_REF("OpenCurlyDoubleQuote;", 0x201c),
  CHAR_REF("OpenCurlyQuote;", 0x2018),
  CHAR_REF("Or;", 0x2a54),
  CHAR_REF("Oscr;", 0x0001d4aa),
  CHAR_REF("Oslash;", 0xd8),
  CHAR_REF("Oslash", 0xd8),
  CHAR_REF("Otilde;", 0xd5),
  CHAR_REF("Otilde", 0xd5),
  CHAR_REF("Otimes;", 0x2a37),
  CHAR_REF("Ouml;", 0xd6),
  CHAR_REF("Ouml", 0xd6),
  CHAR_REF("OverBar;", 0x203e),
  CHAR_REF("OverBrace;", 0x23de),
  CHAR_REF("OverBracket;", 0x23b4),
  CHAR_REF("OverParenthesis;", 0x23dc),
  CHAR_REF("PartialD;", 0x2202),
  CHAR_REF("Pcy;", 0x041f),
  CHAR_REF("Pfr;", 0x0001d513),
  CHAR_REF("Phi;", 0x03a6),
  CHAR_REF("Pi;", 0x03a0),
  CHAR_REF("PlusMinus;", 0xb1),
  CHAR_REF("Poincareplane;", 0x210c),
  CHAR_REF("Popf;", 0x2119),
  CHAR_REF("Pr;", 0x2abb),
  CHAR_REF("Precedes;", 0x227a),
  CHAR_REF("PrecedesEqual;", 0x2aaf),
  CHAR_REF("PrecedesSlantEqual;", 0x227c),
  CHAR_REF("PrecedesTilde;", 0x227e),
  CHAR_REF("Prime;", 0x2033),
  CHAR_REF("Product;", 0x220f),
  CHAR_REF("Proportion;", 0x2237),
  CHAR_REF("Proportional;", 0x221d),
  CHAR_REF("Pscr;", 0x0001d4ab),
  CHAR_REF("Psi;", 0x03a8),
  CHAR_REF("QUOT;", 0x22),
  CHAR_REF("QUOT", 0x22),
  CHAR_REF("Qfr;", 0x0001d514),
  CHAR_REF("Qopf;", 0x211a),
  CHAR_REF("Qscr;", 0x0001d4ac),
  CHAR_REF("RBarr;", 0x2910),
  CHAR_REF("REG;", 0xae),
  CHAR_REF("REG", 0xae),
  CHAR_REF("Racute;", 0x0154),
  CHAR_REF("Rang;", 0x27eb),
  CHAR_REF("Rarr;", 0x21a0),
  CHAR_REF("Rarrtl;", 0x2916),
  CHAR_REF("Rcaron;", 0x0158),
  CHAR_REF("Rcedil;", 0x0156),
  CHAR_REF("Rcy;", 0x0420),
  CHAR_REF("Re;", 0x211c),
  CHAR_REF("ReverseElement;", 0x220b),
  CHAR_REF("ReverseEquilibrium;", 0x21cb),
  CHAR_REF("ReverseUpEquilibrium;", 0x296f),
  CHAR_REF("Rfr;", 0x211c),
  CHAR_REF("Rho;", 0x03a1),
  CHAR_REF("RightAngleBracket;", 0x27e9),
  CHAR_REF("RightArrow;", 0x2192),
  CHAR_REF("RightArrowBar;", 0x21e5),
  CHAR_REF("RightArrowLeftArrow;", 0x21c4),
  CHAR_REF("RightCeiling;", 0x2309),
  CHAR_REF("RightDoubleBracket;", 0x27e7),
  CHAR_REF("RightDownTeeVector;", 0x295d),
  CHAR_REF("RightDownVector;", 0x21c2),
  CHAR_REF("RightDownVectorBar;", 0x2955),
  CHAR_REF("RightFloor;", 0x230b),
  CHAR_REF("RightTee;", 0x22a2),
  CHAR_REF("RightTeeArrow;", 0x21a6),
  CHAR_REF("RightTeeVector;", 0x295b),
  CHAR_REF("RightTriangle;", 0x22b3),
  CHAR_REF("RightTriangleBar;", 0x29d0),
  CHAR_REF("RightTriangleEqual;", 0x22b5),
  CHAR_REF("RightUpDownVector;", 0x294f),
  CHAR_REF("RightUpTeeVector;", 0x295c),
  CHAR_REF("RightUpVector;", 0x21be),
  CHAR_REF("RightUpVectorBar;", 0x2954),
  CHAR_REF("RightVector;", 0x21c0),
  CHAR_REF("RightVectorBar;", 0x2953),
  CHAR_REF("Rightarrow;", 0x21d2),
  CHAR_REF("Ropf;", 0x211d),
  CHAR_REF("RoundImplies;", 0x2970),
  CHAR_REF("Rrightarrow;", 0x21db),
  CHAR_REF("Rscr;", 0x211b),
  CHAR_REF("Rsh;", 0x21b1),
  CHAR_REF("RuleDelayed;", 0x29f4),
  CHAR_REF("SHCHcy;", 0x0429),
  CHAR_REF("SHcy;", 0x0428),
  CHAR_REF("SOFTcy;", 0x042c),
  CHAR_REF("Sacute;", 0x015a),
  CHAR_REF("Sc;", 0x2abc),
  CHAR_REF("Scaron;", 0x0160),
  CHAR_REF("Scedil;", 0x015e),
  CHAR_REF("Scirc;", 0x015c),
  CHAR_REF("Scy;", 0x0421),
  CHAR_REF("Sfr;", 0x0001d516),
  CHAR_REF("ShortDownArrow;", 0x2193),
  CHAR_REF("ShortLeftArrow;", 0x2190),
  CHAR_REF("ShortRightArrow;", 0x2192),
  CHAR_REF("ShortUpArrow;", 0x2191),
  CHAR_REF("Sigma;", 0x03a3),
  CHAR_REF("SmallCircle;", 0x2218),
  CHAR_REF("Sopf;", 0x0001d54a),
  CHAR_REF("Sqrt;", 0x221a),
  CHAR_REF("Square;", 0x25a1),
  CHAR_REF("SquareIntersection;", 0x2293),
  CHAR_REF("SquareSubset;", 0x228f),
  CHAR_REF("SquareSubsetEqual;", 0x2291),
  CHAR_REF("SquareSuperset;", 0x2290),
  CHAR_REF("SquareSupersetEqual;", 0x2292),
  CHAR_REF("SquareUnion;", 0x2294),
  CHAR_REF("Sscr;", 0x0001d4ae),
  CHAR_REF("Star;", 0x22c6),
  CHAR_REF("Sub;", 0x22d0),
  CHAR_REF("Subset;", 0x22d0),
  CHAR_REF("SubsetEqual;", 0x2286),
  CHAR_REF("Succeeds;", 0x227b),
  CHAR_REF("SucceedsEqual;", 0x2ab0),
  CHAR_REF("SucceedsSlantEqual;", 0x227d),
  CHAR_REF("SucceedsTilde;", 0x227f),
  CHAR_REF("SuchThat;", 0x220b),
  CHAR_REF("Sum;", 0x2211),
  CHAR_REF("Sup;", 0x22d1),
  CHAR_REF("Superset;", 0x2283),
  CHAR_REF("SupersetEqual;", 0x2287),
  CHAR_REF("Supset;", 0x22d1),
  CHAR_REF("THORN;", 0xde),
  CHAR_REF("THORN", 0xde),
  CHAR_REF("TRADE;", 0x2122),
  CHAR_REF("TSHcy;", 0x040b),
  CHAR_REF("TScy;", 0x0426),
  CHAR_REF("Tab;", 0x09),
  CHAR_REF("Tau;", 0x03a4),
  CHAR_REF("Tcaron;", 0x0164),
  CHAR_REF("Tcedil;", 0x0162),
  CHAR_REF("Tcy;", 0x0422),
  CHAR_REF("Tfr;", 0x0001d517),
  CHAR_REF("Therefore;", 0x2234),
  CHAR_REF("Theta;", 0x0398),
  MULTI_CHAR_REF("ThickSpace;", 0x205f, 0x200a),
  CHAR_REF("ThinSpace;", 0x2009),
  CHAR_REF("Tilde;", 0x223c),
  CHAR_REF("TildeEqual;", 0x2243),
  CHAR_REF("TildeFullEqual;", 0x2245),
  CHAR_REF("TildeTilde;", 0x2248),
  CHAR_REF("Topf;", 0x0001d54b),
  CHAR_REF("TripleDot;", 0x20db),
  CHAR_REF("Tscr;", 0x0001d4af),
  CHAR_REF("Tstrok;", 0x0166),
  CHAR_REF("Uacute;", 0xda),
  CHAR_REF("Uacute", 0xda),
  CHAR_REF("Uarr;", 0x219f),
  CHAR_REF("Uarrocir;", 0x2949),
  CHAR_REF("Ubrcy;", 0x040e),
  CHAR_REF("Ubreve;", 0x016c),
  CHAR_REF("Ucirc;", 0xdb),
  CHAR_REF("Ucirc", 0xdb),
  CHAR_REF("Ucy;", 0x0423),
  CHAR_REF("Udblac;", 0x0170),
  CHAR_REF("Ufr;", 0x0001d518),
  CHAR_REF("Ugrave;", 0xd9),
  CHAR_REF("Ugrave", 0xd9),
  CHAR_REF("Umacr;", 0x016a),
  CHAR_REF("UnderBar;", 0x5f),
  CHAR_REF("UnderBrace;", 0x23df),
  CHAR_REF("UnderBracket;", 0x23b5),
  CHAR_REF("UnderParenthesis;", 0x23dd),
  CHAR_REF("Union;", 0x22c3),
  CHAR_REF("UnionPlus;", 0x228e),
  CHAR_REF("Uogon;", 0x0172),
  CHAR_REF("Uopf;", 0x0001d54c),
  CHAR_REF("UpArrow;", 0x2191),
  CHAR_REF("UpArrowBar;", 0x2912),
  CHAR_REF("UpArrowDownArrow;", 0x21c5),
  CHAR_REF("UpDownArrow;", 0x2195),
  CHAR_REF("UpEquilibrium;", 0x296e),
  CHAR_REF("UpTee;", 0x22a5),
  CHAR_REF("UpTeeArrow;", 0x21a5),
  CHAR_REF("Uparrow;", 0x21d1),
  CHAR_REF("Updownarrow;", 0x21d5),
  CHAR_REF("UpperLeftArrow;", 0x2196),
  CHAR_REF("UpperRightArrow;", 0x2197),
  CHAR_REF("Upsi;", 0x03d2),
  CHAR_REF("Upsilon;", 0x03a5),
  CHAR_REF("Uring;", 0x016e),
  CHAR_REF("Uscr;", 0x0001d4b0),
  CHAR_REF("Utilde;", 0x0168),
  CHAR_REF("Uuml;", 0xdc),
  CHAR_REF("Uuml", 0xdc),
  CHAR_REF("VDash;", 0x22ab),
  CHAR_REF("Vbar;", 0x2aeb),
  CHAR_REF("Vcy;", 0x0412),
  CHAR_REF("Vdash;", 0x22a9),
  CHAR_REF("Vdashl;", 0x2ae6),
  CHAR_REF("Vee;", 0x22c1),
  CHAR_REF("Verbar;", 0x2016),
  CHAR_REF("Vert;", 0x2016),
  CHAR_REF("VerticalBar;", 0x2223),
  CHAR_REF("VerticalLine;", 0x7c),
  CHAR_REF("VerticalSeparator;", 0x2758),
  CHAR_REF("VerticalTilde;", 0x2240),
  CHAR_REF("VeryThinSpace;", 0x200a),
  CHAR_REF("Vfr;", 0x0001d519),
  CHAR_REF("Vopf;", 0x0001d54d),
  CHAR_REF("Vscr;", 0x0001d4b1),
  CHAR_REF("Vvdash;", 0x22aa),
  CHAR_REF("Wcirc;", 0x0174),
  CHAR_REF("Wedge;", 0x22c0),
  CHAR_REF("Wfr;", 0x0001d51a),
  CHAR_REF("Wopf;", 0x0001d54e),
  CHAR_REF("Wscr;", 0x0001d4b2),
  CHAR_REF("Xfr;", 0x0001d51b),
  CHAR_REF("Xi;", 0x039e),
  CHAR_REF("Xopf;", 0x0001d54f),
  CHAR_REF("Xscr;", 0x0001d4b3),
  CHAR_REF("YAcy;", 0x042f),
  CHAR_REF("YIcy;", 0x0407),
  CHAR_REF("YUcy;", 0x042e),
  CHAR_REF("Yacute;", 0xdd),
  CHAR_REF("Yacute", 0xdd),
  CHAR_REF("Ycirc;", 0x0176),
  CHAR_REF("Ycy;", 0x042b),
  CHAR_REF("Yfr;", 0x0001d51c),
  CHAR_REF("Yopf;", 0x0001d550),
  CHAR_REF("Yscr;", 0x0001d4b4),
  CHAR_REF("Yuml;", 0x0178),
  CHAR_REF("ZHcy;", 0x0416),
  CHAR_REF("Zacute;", 0x0179),
  CHAR_REF("Zcaron;", 0x017d),
  CHAR_REF("Zcy;", 0x0417),
  CHAR_REF("Zdot;", 0x017b),
  CHAR_REF("ZeroWidthSpace;", 0x200b),
  CHAR_REF("Zeta;", 0x0396),
  CHAR_REF("Zfr;", 0x2128),
  CHAR_REF("Zopf;", 0x2124),
  CHAR_REF("Zscr;", 0x0001d4b5),
  CHAR_REF("aacute;", 0xe1),
  CHAR_REF("aacute", 0xe1),
  CHAR_REF("abreve;", 0x0103),
  CHAR_REF("ac;", 0x223e),
  MULTI_CHAR_REF("acE;", 0x223e, 0x0333),
  CHAR_REF("acd;", 0x223f),
  CHAR_REF("acirc;", 0xe2),
  CHAR_REF("acirc", 0xe2),
  CHAR_REF("acute;", 0xb4),
  CHAR_REF("acute", 0xb4),
  CHAR_REF("acy;", 0x0430),
  CHAR_REF("aelig;", 0xe6),
  CHAR_REF("aelig", 0xe6),
  CHAR_REF("af;", 0x2061),
  CHAR_REF("afr;", 0x0001d51e),
  CHAR_REF("agrave;", 0xe0),
  CHAR_REF("agrave", 0xe0),
  CHAR_REF("alefsym;", 0x2135),
  CHAR_REF("aleph;", 0x2135),
  CHAR_REF("alpha;", 0x03b1),
  CHAR_REF("amacr;", 0x0101),
  CHAR_REF("amalg;", 0x2a3f),
  CHAR_REF("amp;", 0x26),
  CHAR_REF("amp", 0x26),
  CHAR_REF("and;", 0x2227),
  CHAR_REF("andand;", 0x2a55),
  CHAR_REF("andd;", 0x2a5c),
  CHAR_REF("andslope;", 0x2a58),
  CHAR_REF("andv;", 0x2a5a),
  CHAR_REF("ang;", 0x2220),
  CHAR_REF("ange;", 0x29a4),
  CHAR_REF("angle;", 0x2220),
  CHAR_REF("angmsd;", 0x2221),
  CHAR_REF("angmsdaa;", 0x29a8),
  CHAR_REF("angmsdab;", 0x29a9),
  CHAR_REF("angmsdac;", 0x29aa),
  CHAR_REF("angmsdad;", 0x29ab),
  CHAR_REF("angmsdae;", 0x29ac),
  CHAR_REF("angmsdaf;", 0x29ad),
  CHAR_REF("angmsdag;", 0x29ae),
  CHAR_REF("angmsdah;", 0x29af),
  CHAR_REF("angrt;", 0x221f),
  CHAR_REF("angrtvb;", 0x22be),
  CHAR_REF("angrtvbd;", 0x299d),
  CHAR_REF("angsph;", 0x2222),
  CHAR_REF("angst;", 0xc5),
  CHAR_REF("angzarr;", 0x237c),
  CHAR_REF("aogon;", 0x0105),
  CHAR_REF("aopf;", 0x0001d552),
  CHAR_REF("ap;", 0x2248),
  CHAR_REF("apE;", 0x2a70),
  CHAR_REF("apacir;", 0x2a6f),
  CHAR_REF("ape;", 0x224a),
  CHAR_REF("apid;", 0x224b),
  CHAR_REF("apos;", 0x27),
  CHAR_REF("approx;", 0x2248),
  CHAR_REF("approxeq;", 0x224a),
  CHAR_REF("aring;", 0xe5),
  CHAR_REF("aring", 0xe5),
  CHAR_REF("ascr;", 0x0001d4b6),
  CHAR_REF("ast;", 0x2a),
  CHAR_REF("asymp;", 0x2248),
  CHAR_REF("asympeq;", 0x224d),
  CHAR_REF("atilde;", 0xe3),
  CHAR_REF("atilde", 0xe3),
  CHAR_REF("auml;", 0xe4),
  CHAR_REF("auml", 0xe4),
  CHAR_REF("awconint;", 0x2233),
  CHAR_REF("awint;", 0x2a11),
  CHAR_REF("bNot;", 0x2aed),
  CHAR_REF("backcong;", 0x224c),
  CHAR_REF("backepsilon;", 0x03f6),
  CHAR_REF("backprime;", 0x2035),
  CHAR_REF("backsim;", 0x223d),
  CHAR_REF("backsimeq;", 0x22cd),
  CHAR_REF("barvee;", 0x22bd),
  CHAR_REF("barwed;", 0x2305),
  CHAR_REF("barwedge;", 0x2305),
  CHAR_REF("bbrk;", 0x23b5),
  CHAR_REF("bbrktbrk;", 0x23b6),
  CHAR_REF("bcong;", 0x224c),
  CHAR_REF("bcy;", 0x0431),
  CHAR_REF("bdquo;", 0x201e),
  CHAR_REF("becaus;", 0x2235),
  CHAR_REF("because;", 0x2235),
  CHAR_REF("bemptyv;", 0x29b0),
  CHAR_REF("bepsi;", 0x03f6),
  CHAR_REF("bernou;", 0x212c),
  CHAR_REF("beta;", 0x03b2),
  CHAR_REF("beth;", 0x2136),
  CHAR_REF("between;", 0x226c),
  CHAR_REF("bfr;", 0x0001d51f),
  CHAR_REF("bigcap;", 0x22c2),
  CHAR_REF("bigcirc;", 0x25ef),
  CHAR_REF("bigcup;", 0x22c3),
  CHAR_REF("bigodot;", 0x2a00),
  CHAR_REF("bigoplus;", 0x2a01),
  CHAR_REF("bigotimes;", 0x2a02),
  CHAR_REF("bigsqcup;", 0x2a06),
  CHAR_REF("bigstar;", 0x2605),
  CHAR_REF("bigtriangledown;", 0x25bd),
  CHAR_REF("bigtriangleup;", 0x25b3),
  CHAR_REF("biguplus;", 0x2a04),
  CHAR_REF("bigvee;", 0x22c1),
  CHAR_REF("bigwedge;", 0x22c0),
  CHAR_REF("bkarow;", 0x290d),
  CHAR_REF("blacklozenge;", 0x29eb),
  CHAR_REF("blacksquare;", 0x25aa),
  CHAR_REF("blacktriangle;", 0x25b4),
  CHAR_REF("blacktriangledown;", 0x25be),
  CHAR_REF("blacktriangleleft;", 0x25c2),
  CHAR_REF("blacktriangleright;", 0x25b8),
  CHAR_REF("blank;", 0x2423),
  CHAR_REF("blk12;", 0x2592),
  CHAR_REF("blk14;", 0x2591),
  CHAR_REF("blk34;", 0x2593),
  CHAR_REF("block;", 0x2588),
  MULTI_CHAR_REF("bne;", 0x3d, 0x20e5),
  MULTI_CHAR_REF("bnequiv;", 0x2261, 0x20e5),
  CHAR_REF("bnot;", 0x2310),
  CHAR_REF("bopf;", 0x0001d553),
  CHAR_REF("bot;", 0x22a5),
  CHAR_REF("bottom;", 0x22a5),
  CHAR_REF("bowtie;", 0x22c8),
  CHAR_REF("boxDL;", 0x2557),
  CHAR_REF("boxDR;", 0x2554),
  CHAR_REF("boxDl;", 0x2556),
  CHAR_REF("boxDr;", 0x2553),
  CHAR_REF("boxH;", 0x2550),
  CHAR_REF("boxHD;", 0x2566),
  CHAR_REF("boxHU;", 0x2569),
  CHAR_REF("boxHd;", 0x2564),
  CHAR_REF("boxHu;", 0x2567),
  CHAR_REF("boxUL;", 0x255d),
  CHAR_REF("boxUR;", 0x255a),
  CHAR_REF("boxUl;", 0x255c),
  CHAR_REF("boxUr;", 0x2559),
  CHAR_REF("boxV;", 0x2551),
  CHAR_REF("boxVH;", 0x256c),
  CHAR_REF("boxVL;", 0x2563),
  CHAR_REF("boxVR;", 0x2560),
  CHAR_REF("boxVh;", 0x256b),
  CHAR_REF("boxVl;", 0x2562),
  CHAR_REF("boxVr;", 0x255f),
  CHAR_REF("boxbox;", 0x29c9),
  CHAR_REF("boxdL;", 0x2555),
  CHAR_REF("boxdR;", 0x2552),
  CHAR_REF("boxdl;", 0x2510),
  CHAR_REF("boxdr;", 0x250c),
  CHAR_REF("boxh;", 0x2500),
  CHAR_REF("boxhD;", 0x2565),
  CHAR_REF("boxhU;", 0x2568),
  CHAR_REF("boxhd;", 0x252c),
  CHAR_REF("boxhu;", 0x2534),
  CHAR_REF("boxminus;", 0x229f),
  CHAR_REF("boxplus;", 0x229e),
  CHAR_REF("boxtimes;", 0x22a0),
  CHAR_REF("boxuL;", 0x255b),
  CHAR_REF("boxuR;", 0x2558),
  CHAR_REF("boxul;", 0x2518),
  CHAR_REF("boxur;", 0x2514),
  CHAR_REF("boxv;", 0x2502),
  CHAR_REF("boxvH;", 0x256a),
  CHAR_REF("boxvL;", 0x2561),
  CHAR_REF("boxvR;", 0x255e),
  CHAR_REF("boxvh;", 0x253c),
  CHAR_REF("boxvl;", 0x2524),
  CHAR_REF("boxvr;", 0x251c),
  CHAR_REF("bprime;", 0x2035),
  CHAR_REF("breve;", 0x02d8),
  CHAR_REF("brvbar;", 0xa6),
  CHAR_REF("brvbar", 0xa6),
  CHAR_REF("bscr;", 0x0001d4b7),
  CHAR_REF("bsemi;", 0x204f),
  CHAR_REF("bsim;", 0x223d),
  CHAR_REF("bsime;", 0x22cd),
  CHAR_REF("bsol;", 0x5c),
  CHAR_REF("bsolb;", 0x29c5),
  CHAR_REF("bsolhsub;", 0x27c8),
  CHAR_REF("bull;", 0x2022),
  CHAR_REF("bullet;", 0x2022),
  CHAR_REF("bump;", 0x224e),
  CHAR_REF("bumpE;", 0x2aae),
  CHAR_REF("bumpe;", 0x224f),
  CHAR_REF("bumpeq;", 0x224f),
  CHAR_REF("cacute;", 0x0107),
  CHAR_REF("cap;", 0x2229),
  CHAR_REF("capand;", 0x2a44),
  CHAR_REF("capbrcup;", 0x2a49),
  CHAR_REF("capcap;", 0x2a4b),
  CHAR_REF("capcup;", 0x2a47),
  CHAR_REF("capdot;", 0x2a40),
  MULTI_CHAR_REF("caps;", 0x2229, 0xfe00),
  CHAR_REF("caret;", 0x2041),
  CHAR_REF("caron;", 0x02c7),
  CHAR_REF("ccaps;", 0x2a4d),
  CHAR_REF("ccaron;", 0x010d),
  CHAR_REF("ccedil;", 0xe7),
  CHAR_REF("ccedil", 0xe7),
  CHAR_REF("ccirc;", 0x0109),
  CHAR_REF("ccups;", 0x2a4c),
  CHAR_REF("ccupssm;", 0x2a50),
  CHAR_REF("cdot;", 0x010b),
  CHAR_REF("cedil;", 0xb8),
  CHAR_REF("cedil", 0xb8),
  CHAR_REF("cemptyv;", 0x29b2),
  CHAR_REF("cent;", 0xa2),
  CHAR_REF("cent", 0xa2),
  CHAR_REF("centerdot;", 0xb7),
  CHAR_REF("cfr;", 0x0001d520),
  CHAR_REF("chcy;", 0x0447),
  CHAR_REF("check;", 0x2713),
  CHAR_REF("checkmark;", 0x2713),
  CHAR_REF("chi;", 0x03c7),
  CHAR_REF("cir;", 0x25cb),
  CHAR_REF("cirE;", 0x29c3),
  CHAR_REF("circ;", 0x02c6),
  CHAR_REF("circeq;", 0x2257),
  CHAR_REF("circlearrowleft;", 0x21ba),
  CHAR_REF("circlearrowright;", 0x21bb),
  CHAR_REF("circledR;", 0xae),
  CHAR_REF("circledS;", 0x24c8),
  CHAR_REF("circledast;", 0x229b),
  CHAR_REF("circledcirc;", 0x229a),
  CHAR_REF("circleddash;", 0x229d),
  CHAR_REF("cire;", 0x2257),
  CHAR_REF("cirfnint;", 0x2a10),
  CHAR_REF("cirmid;", 0x2aef),
  CHAR_REF("cirscir;", 0x29c2),
  CHAR_REF("clubs;", 0x2663),
  CHAR_REF("clubsuit;", 0x2663),
  CHAR_REF("colon;", 0x3a),
  CHAR_REF("colone;", 0x2254),
  CHAR_REF("coloneq;", 0x2254),
  CHAR_REF("comma;", 0x2c),
  CHAR_REF("commat;", 0x40),
  CHAR_REF("comp;", 0x2201),
  CHAR_REF("compfn;", 0x2218),
  CHAR_REF("complement;", 0x2201),
  CHAR_REF("complexes;", 0x2102),
  CHAR_REF("cong;", 0x2245),
  CHAR_REF("congdot;", 0x2a6d),
  CHAR_REF("conint;", 0x222e),
  CHAR_REF("copf;", 0x0001d554),
  CHAR_REF("coprod;", 0x2210),
  CHAR_REF("copy;", 0xa9),
  CHAR_REF("copy", 0xa9),
  CHAR_REF("copysr;", 0x2117),
  CHAR_REF("crarr;", 0x21b5),
  CHAR_REF("cross;", 0x2717),
  CHAR_REF("cscr;", 0x0001d4b8),
  CHAR_REF("csub;", 0x2acf),
  CHAR_REF("csube;", 0x2ad1),
  CHAR_REF("csup;", 0x2ad0),
  CHAR_REF("csupe;", 0x2ad2),
  CHAR_REF("ctdot;", 0x22ef),
  CHAR_REF("cudarrl;", 0x2938),
  CHAR_REF("cudarrr;", 0x2935),
  CHAR_REF("cuepr;", 0x22de),
  CHAR_REF("cuesc;", 0x22df),
  CHAR_REF("cularr;", 0x21b6),
  CHAR_REF("cularrp;", 0x293d),
  CHAR_REF("cup;", 0x222a),
  CHAR_REF("cupbrcap;", 0x2a48),
  CHAR_REF("cupcap;", 0x2a46),
  CHAR_REF("cupcup;", 0x2a4a),
  CHAR_REF("cupdot;", 0x228d),
  CHAR_REF("cupor;", 0x2a45),
  MULTI_CHAR_REF("cups;", 0x222a, 0xfe00),
  CHAR_REF("curarr;", 0x21b7),
  CHAR_REF("curarrm;", 0x293c),
  CHAR_REF("curlyeqprec;", 0x22de),
  CHAR_REF("curlyeqsucc;", 0x22df),
  CHAR_REF("curlyvee;", 0x22ce),
  CHAR_REF("curlywedge;", 0x22cf),
  CHAR_REF("curren;", 0xa4),
  CHAR_REF("curren", 0xa4),
  CHAR_REF("curvearrowleft;", 0x21b6),
  CHAR_REF("curvearrowright;", 0x21b7),
  CHAR_REF("cuvee;", 0x22ce),
  CHAR_REF("cuwed;", 0x22cf),
  CHAR_REF("cwconint;", 0x2232),
  CHAR_REF("cwint;", 0x2231),
  CHAR_REF("cylcty;", 0x232d),
  CHAR_REF("dArr;", 0x21d3),
  CHAR_REF("dHar;", 0x2965),
  CHAR_REF("dagger;", 0x2020),
  CHAR_REF("daleth;", 0x2138),
  CHAR_REF("darr;", 0x2193),
  CHAR_REF("dash;", 0x2010),
  CHAR_REF("dashv;", 0x22a3),
  CHAR_REF("dbkarow;", 0x290f),
  CHAR_REF("dblac;", 0x02dd),
  CHAR_REF("dcaron;", 0x010f),
  CHAR_REF("dcy;", 0x0434),
  CHAR_REF("dd;", 0x2146),
  CHAR_REF("ddagger;", 0x2021),
  CHAR_REF("ddarr;", 0x21ca),
  CHAR_REF("ddotseq;", 0x2a77),
  CHAR_REF("deg;", 0xb0),
  CHAR_REF("deg", 0xb0),
  CHAR_REF("delta;", 0x03b4),
  CHAR_REF("demptyv;", 0x29b1),
  CHAR_REF("dfisht;", 0x297f),
  CHAR_REF("dfr;", 0x0001d521),
  CHAR_REF("dharl;", 0x21c3),
  CHAR_REF("dharr;", 0x21c2),
  CHAR_REF("diam;", 0x22c4),
  CHAR_REF("diamond;", 0x22c4),
  CHAR_REF("diamondsuit;", 0x2666),
  CHAR_REF("diams;", 0x2666),
  CHAR_REF("die;", 0xa8),
  CHAR_REF("digamma;", 0x03dd),
  CHAR_REF("disin;", 0x22f2),
  CHAR_REF("div;", 0xf7),
  CHAR_REF("divide;", 0xf7),
  CHAR_REF("divide", 0xf7),
  CHAR_REF("divideontimes;", 0x22c7),
  CHAR_REF("divonx;", 0x22c7),
  CHAR_REF("djcy;", 0x0452),
  CHAR_REF("dlcorn;", 0x231e),
  CHAR_REF("dlcrop;", 0x230d),
  CHAR_REF("dollar;", 0x24),
  CHAR_REF("dopf;", 0x0001d555),
  CHAR_REF("dot;", 0x02d9),
  CHAR_REF("doteq;", 0x2250),
  CHAR_REF("doteqdot;", 0x2251),
  CHAR_REF("dotminus;", 0x2238),
  CHAR_REF("dotplus;", 0x2214),
  CHAR_REF("dotsquare;", 0x22a1),
  CHAR_REF("doublebarwedge;", 0x2306),
  CHAR_REF("downarrow;", 0x2193),
  CHAR_REF("downdownarrows;", 0x21ca),
  CHAR_REF("downharpoonleft;", 0x21c3),
  CHAR_REF("downharpoonright;", 0x21c2),
  CHAR_REF("drbkarow;", 0x2910),
  CHAR_REF("drcorn;", 0x231f),
  CHAR_REF("drcrop;", 0x230c),
  CHAR_REF("dscr;", 0x0001d4b9),
  CHAR_REF("dscy;", 0x0455),
  CHAR_REF("dsol;", 0x29f6),
  CHAR_REF("dstrok;", 0x0111),
  CHAR_REF("dtdot;", 0x22f1),
  CHAR_REF("dtri;", 0x25bf),
  CHAR_REF("dtrif;", 0x25be),
  CHAR_REF("duarr;", 0x21f5),
  CHAR_REF("duhar;", 0x296f),
  CHAR_REF("dwangle;", 0x29a6),
  CHAR_REF("dzcy;", 0x045f),
  CHAR_REF("dzigrarr;", 0x27ff),
  CHAR_REF("eDDot;", 0x2a77),
  CHAR_REF("eDot;", 0x2251),
  CHAR_REF("eacute;", 0xe9),
  CHAR_REF("eacute", 0xe9),
  CHAR_REF("easter;", 0x2a6e),
  CHAR_REF("ecaron;", 0x011b),
  CHAR_REF("ecir;", 0x2256),
  CHAR_REF("ecirc;", 0xea),
  CHAR_REF("ecirc", 0xea),
  CHAR_REF("ecolon;", 0x2255),
  CHAR_REF("ecy;", 0x044d),
  CHAR_REF("edot;", 0x0117),
  CHAR_REF("ee;", 0x2147),
  CHAR_REF("efDot;", 0x2252),
  CHAR_REF("efr;", 0x0001d522),
  CHAR_REF("eg;", 0x2a9a),
  CHAR_REF("egrave;", 0xe8),
  CHAR_REF("egrave", 0xe8),
  CHAR_REF("egs;", 0x2a96),
  CHAR_REF("egsdot;", 0x2a98),
  CHAR_REF("el;", 0x2a99),
  CHAR_REF("elinters;", 0x23e7),
  CHAR_REF("ell;", 0x2113),
  CHAR_REF("els;", 0x2a95),
  CHAR_REF("elsdot;", 0x2a97),
  CHAR_REF("emacr;", 0x0113),
  CHAR_REF("empty;", 0x2205),
  CHAR_REF("emptyset;", 0x2205),
  CHAR_REF("emptyv;", 0x2205),
  CHAR_REF("emsp13;", 0x2004),
  CHAR_REF("emsp14;", 0x2005),
  CHAR_REF("emsp;", 0x2003),
  CHAR_REF("eng;", 0x014b),
  CHAR_REF("ensp;", 0x2002),
  CHAR_REF("eogon;", 0x0119),
  CHAR_REF("eopf;", 0x0001d556),
  CHAR_REF("epar;", 0x22d5),
  CHAR_REF("eparsl;", 0x29e3),
  CHAR_REF("eplus;", 0x2a71),
  CHAR_REF("epsi;", 0x03b5),
  CHAR_REF("epsilon;", 0x03b5),
  CHAR_REF("epsiv;", 0x03f5),
  CHAR_REF("eqcirc;", 0x2256),
  CHAR_REF("eqcolon;", 0x2255),
  CHAR_REF("eqsim;", 0x2242),
  CHAR_REF("eqslantgtr;", 0x2a96),
  CHAR_REF("eqslantless;", 0x2a95),
  CHAR_REF("equals;", 0x3d),
  CHAR_REF("equest;", 0x225f),
  CHAR_REF("equiv;", 0x2261),
  CHAR_REF("equivDD;", 0x2a78),
  CHAR_REF("eqvparsl;", 0x29e5),
  CHAR_REF("erDot;", 0x2253),
  CHAR_REF("erarr;", 0x2971),
  CHAR_REF("escr;", 0x212f),
  CHAR_REF("esdot;", 0x2250),
  CHAR_REF("esim;", 0x2242),
  CHAR_REF("eta;", 0x03b7),
  CHAR_REF("eth;", 0xf0),
  CHAR_REF("eth", 0xf0),
  CHAR_REF("euml;", 0xeb),
  CHAR_REF("euml", 0xeb),
  CHAR_REF("euro;", 0x20ac),
  CHAR_REF("excl;", 0x21),
  CHAR_REF("exist;", 0x2203),
  CHAR_REF("expectation;", 0x2130),
  CHAR_REF("exponentiale;", 0x2147),
  CHAR_REF("fallingdotseq;", 0x2252),
  CHAR_REF("fcy;", 0x0444),
  CHAR_REF("female;", 0x2640),
  CHAR_REF("ffilig;", 0xfb03),
  CHAR_REF("fflig;", 0xfb00),
  CHAR_REF("ffllig;", 0xfb04),
  CHAR_REF("ffr;", 0x0001d523),
  CHAR_REF("filig;", 0xfb01),
  MULTI_CHAR_REF("fjlig;", 0x66, 0x6a),
  CHAR_REF("flat;", 0x266d),
  CHAR_REF("fllig;", 0xfb02),
  CHAR_REF("fltns;", 0x25b1),
  CHAR_REF("fnof;", 0x0192),
  CHAR_REF("fopf;", 0x0001d557),
  CHAR_REF("forall;", 0x2200),
  CHAR_REF("fork;", 0x22d4),
  CHAR_REF("forkv;", 0x2ad9),
  CHAR_REF("fpartint;", 0x2a0d),
  CHAR_REF("frac12;", 0xbd),
  CHAR_REF("frac12", 0xbd),
  CHAR_REF("frac13;", 0x2153),
  CHAR_REF("frac14;", 0xbc),
  CHAR_REF("frac14", 0xbc),
  CHAR_REF("frac15;", 0x2155),
  CHAR_REF("frac16;", 0x2159),
  CHAR_REF("frac18;", 0x215b),
  CHAR_REF("frac23;", 0x2154),
  CHAR_REF("frac25;", 0x2156),
  CHAR_REF("frac34;", 0xbe),
  CHAR_REF("frac34", 0xbe),
  CHAR_REF("frac35;", 0x2157),
  CHAR_REF("frac38;", 0x215c),
  CHAR_REF("frac45;", 0x2158),
  CHAR_REF("frac56;", 0x215a),
  CHAR_REF("frac58;", 0x215d),
  CHAR_REF("frac78;", 0x215e),
  CHAR_REF("frasl;", 0x2044),
  CHAR_REF("frown;", 0x2322),
  CHAR_REF("fscr;", 0x0001d4bb),
  CHAR_REF("gE;", 0x2267),
  CHAR_REF("gEl;", 0x2a8c),
  CHAR_REF("gacute;", 0x01f5),
  CHAR_REF("gamma;", 0x03b3),
  CHAR_REF("gammad;", 0x03dd),
  CHAR_REF("gap;", 0x2a86),
  CHAR_REF("gbreve;", 0x011f),
  CHAR_REF("gcirc;", 0x011d),
  CHAR_REF("gcy;", 0x0433),
  CHAR_REF("gdot;", 0x0121),
  CHAR_REF("ge;", 0x2265),
  CHAR_REF("gel;", 0x22db),
  CHAR_REF("geq;", 0x2265),
  CHAR_REF("geqq;", 0x2267),
  CHAR_REF("geqslant;", 0x2a7e),
  CHAR_REF("ges;", 0x2a7e),
  CHAR_REF("gescc;", 0x2aa9),
  CHAR_REF("gesdot;", 0x2a80),
  CHAR_REF("gesdoto;", 0x2a82),
  CHAR_REF("gesdotol;", 0x2a84),
  MULTI_CHAR_REF("gesl;", 0x22db, 0xfe00),
  CHAR_REF("gesles;", 0x2a94),
  CHAR_REF("gfr;", 0x0001d524),
  CHAR_REF("gg;", 0x226b),
  CHAR_REF("ggg;", 0x22d9),
  CHAR_REF("gimel;", 0x2137),
  CHAR_REF("gjcy;", 0x0453),
  CHAR_REF("gl;", 0x2277),
  CHAR_REF("glE;", 0x2a92),
  CHAR_REF("gla;", 0x2aa5),
  CHAR_REF("glj;", 0x2aa4),
  CHAR_REF("gnE;", 0x2269),
  CHAR_REF("gnap;", 0x2a8a),
  CHAR_REF("gnapprox;", 0x2a8a),
  CHAR_REF("gne;", 0x2a88),
  CHAR_REF("gneq;", 0x2a88),
  CHAR_REF("gneqq;", 0x2269),
  CHAR_REF("gnsim;", 0x22e7),
  CHAR_REF("gopf;", 0x0001d558),
  CHAR_REF("grave;", 0x60),
  CHAR_REF("gscr;", 0x210a),
  CHAR_REF("gsim;", 0x2273),
  CHAR_REF("gsime;", 0x2a8e),
  CHAR_REF("gsiml;", 0x2a90),
  CHAR_REF("gt;", 0x3e),
  CHAR_REF("gt", 0x3e),
  CHAR_REF("gtcc;", 0x2aa7),
  CHAR_REF("gtcir;", 0x2a7a),
  CHAR_REF("gtdot;", 0x22d7),
  CHAR_REF("gtlPar;", 0x2995),
  CHAR_REF("gtquest;", 0x2a7c),
  CHAR_REF("gtrapprox;", 0x2a86),
  CHAR_REF("gtrarr;", 0x2978),
  CHAR_REF("gtrdot;", 0x22d7),
  CHAR_REF("gtreqless;", 0x22db),
  CHAR_REF("gtreqqless;", 0x2a8c),
  CHAR_REF("gtrless;", 0x2277),
  CHAR_REF("gtrsim;", 0x2273),
  MULTI_CHAR_REF("gvertneqq;", 0x2269, 0xfe00),
  MULTI_CHAR_REF("gvnE;", 0x2269, 0xfe00),
  CHAR_REF("hArr;", 0x21d4),
  CHAR_REF("hairsp;", 0x200a),
  CHAR_REF("half;", 0xbd),
  CHAR_REF("hamilt;", 0x210b),
  CHAR_REF("hardcy;", 0x044a),
  CHAR_REF("harr;", 0x2194),
  CHAR_REF("harrcir;", 0x2948),
  CHAR_REF("harrw;", 0x21ad),
  CHAR_REF("hbar;", 0x210f),
  CHAR_REF("hcirc;", 0x0125),
  CHAR_REF("hearts;", 0x2665),
  CHAR_REF("heartsuit;", 0x2665),
  CHAR_REF("hellip;", 0x2026),
  CHAR_REF("hercon;", 0x22b9),
  CHAR_REF("hfr;", 0x0001d525),
  CHAR_REF("hksearow;", 0x2925),
  CHAR_REF("hkswarow;", 0x2926),
  CHAR_REF("hoarr;", 0x21ff),
  CHAR_REF("homtht;", 0x223b),
  CHAR_REF("hookleftarrow;", 0x21a9),
  CHAR_REF("hookrightarrow;", 0x21aa),
  CHAR_REF("hopf;", 0x0001d559),
  CHAR_REF("horbar;", 0x2015),
  CHAR_REF("hscr;", 0x0001d4bd),
  CHAR_REF("hslash;", 0x210f),
  CHAR_REF("hstrok;", 0x0127),
  CHAR_REF("hybull;", 0x2043),
  CHAR_REF("hyphen;", 0x2010),
  CHAR_REF("iacute;", 0xed),
  CHAR_REF("iacute", 0xed),
  CHAR_REF("ic;", 0x2063),
  CHAR_REF("icirc;", 0xee),
  CHAR_REF("icirc", 0xee),
  CHAR_REF("icy;", 0x0438),
  CHAR_REF("iecy;", 0x0435),
  CHAR_REF("iexcl;", 0xa1),
  CHAR_REF("iexcl", 0xa1),
  CHAR_REF("iff;", 0x21d4),
  CHAR_REF("ifr;", 0x0001d526),
  CHAR_REF("igrave;", 0xec),
  CHAR_REF("igrave", 0xec),
  CHAR_REF("ii;", 0x2148),
  CHAR_REF("iiiint;", 0x2a0c),
  CHAR_REF("iiint;", 0x222d),
  CHAR_REF("iinfin;", 0x29dc),
  CHAR_REF("iiota;", 0x2129),
  CHAR_REF("ijlig;", 0x0133),
  CHAR_REF("imacr;", 0x012b),
  CHAR_REF("image;", 0x2111),
  CHAR_REF("imagline;", 0x2110),
  CHAR_REF("imagpart;", 0x2111),
  CHAR_REF("imath;", 0x0131),
  CHAR_REF("imof;", 0x22b7),
  CHAR_REF("imped;", 0x01b5),
  CHAR_REF("in;", 0x2208),
  CHAR_REF("incare;", 0x2105),
  CHAR_REF("infin;", 0x221e),
  CHAR_REF("infintie;", 0x29dd),
  CHAR_REF("inodot;", 0x0131),
  CHAR_REF("int;", 0x222b),
  CHAR_REF("intcal;", 0x22ba),
  CHAR_REF("integers;", 0x2124),
  CHAR_REF("intercal;", 0x22ba),
  CHAR_REF("intlarhk;", 0x2a17),
  CHAR_REF("intprod;", 0x2a3c),
  CHAR_REF("iocy;", 0x0451),
  CHAR_REF("iogon;", 0x012f),
  CHAR_REF("iopf;", 0x0001d55a),
  CHAR_REF("iota;", 0x03b9),
  CHAR_REF("iprod;", 0x2a3c),
  CHAR_REF("iquest;", 0xbf),
  CHAR_REF("iquest", 0xbf),
  CHAR_REF("iscr;", 0x0001d4be),
  CHAR_REF("isin;", 0x2208),
  CHAR_REF("isinE;", 0x22f9),
  CHAR_REF("isindot;", 0x22f5),
  CHAR_REF("isins;", 0x22f4),
  CHAR_REF("isinsv;", 0x22f3),
  CHAR_REF("isinv;", 0x2208),
  CHAR_REF("it;", 0x2062),
  CHAR_REF("itilde;", 0x0129),
  CHAR_REF("iukcy;", 0x0456),
  CHAR_REF("iuml;", 0xef),
  CHAR_REF("iuml", 0xef),
  CHAR_REF("jcirc;", 0x0135),
  CHAR_REF("jcy;", 0x0439),
  CHAR_REF("jfr;", 0x0001d527),
  CHAR_REF("jmath;", 0x0237),
  CHAR_REF("jopf;", 0x0001d55b),
  CHAR_REF("jscr;", 0x0001d4bf),
  CHAR_REF("jsercy;", 0x0458),
  CHAR_REF("jukcy;", 0x0454),
  CHAR_REF("kappa;", 0x03ba),
  CHAR_REF("kappav;", 0x03f0),
  CHAR_REF("kcedil;", 0x0137),
  CHAR_REF("kcy;", 0x043a),
  CHAR_REF("kfr;", 0x0001d528),
  CHAR_REF("kgreen;", 0x0138),
  CHAR_REF("khcy;", 0x0445),
  CHAR_REF("kjcy;", 0x045c),
  CHAR_REF("kopf;", 0x0001d55c),
  CHAR_REF("kscr;", 0x0001d4c0),
  CHAR_REF("lAarr;", 0x21da),
  CHAR_REF("lArr;", 0x21d0),
  CHAR_REF("lAtail;", 0x291b),
  CHAR_REF("lBarr;", 0x290e),
  CHAR_REF("lE;", 0x2266),
  CHAR_REF("lEg;", 0x2a8b),
  CHAR_REF("lHar;", 0x2962),
  CHAR_REF("lacute;", 0x013a),
  CHAR_REF("laemptyv;", 0x29b4),
  CHAR_REF("lagran;", 0x2112),
  CHAR_REF("lambda;", 0x03bb),
  CHAR_REF("lang;", 0x27e8),
  CHAR_REF("langd;", 0x2991),
  CHAR_REF("langle;", 0x27e8),
  CHAR_REF("lap;", 0x2a85),
  CHAR_REF("laquo;", 0xab),
  CHAR_REF("laquo", 0xab),
  CHAR_REF("larr;", 0x2190),
  CHAR_REF("larrb;", 0x21e4),
  CHAR_REF("larrbfs;", 0x291f),
  CHAR_REF("larrfs;", 0x291d),
  CHAR_REF("larrhk;", 0x21a9),
  CHAR_REF("larrlp;", 0x21ab),
  CHAR_REF("larrpl;", 0x2939),
  CHAR_REF("larrsim;", 0x2973),
  CHAR_REF("larrtl;", 0x21a2),
  CHAR_REF("lat;", 0x2aab),
  CHAR_REF("latail;", 0x2919),
  CHAR_REF("late;", 0x2aad),
  MULTI_CHAR_REF("lates;", 0x2aad, 0xfe00),
  CHAR_REF("lbarr;", 0x290c),
  CHAR_REF("lbbrk;", 0x2772),
  CHAR_REF("lbrace;", 0x7b),
  CHAR_REF("lbrack;", 0x5b),
  CHAR_REF("lbrke;", 0x298b),
  CHAR_REF("lbrksld;", 0x298f),
  CHAR_REF("lbrkslu;", 0x298d),
  CHAR_REF("lcaron;", 0x013e),
  CHAR_REF("lcedil;", 0x013c),
  CHAR_REF("lceil;", 0x2308),
  CHAR_REF("lcub;", 0x7b),
  CHAR_REF("lcy;", 0x043b),
  CHAR_REF("ldca;", 0x2936),
  CHAR_REF("ldquo;", 0x201c),
  CHAR_REF("ldquor;", 0x201e),
  CHAR_REF("ldrdhar;", 0x2967),
  CHAR_REF("ldrushar;", 0x294b),
  CHAR_REF("ldsh;", 0x21b2),
  CHAR_REF("le;", 0x2264),
  CHAR_REF("leftarrow;", 0x2190),
  CHAR_REF("leftarrowtail;", 0x21a2),
  CHAR_REF("leftharpoondown;", 0x21bd),
  CHAR_REF("leftharpoonup;", 0x21bc),
  CHAR_REF("leftleftarrows;", 0x21c7),
  CHAR_REF("leftrightarrow;", 0x2194),
  CHAR_REF("leftrightarrows;", 0x21c6),
  CHAR_REF("leftrightharpoons;", 0x21cb),
  CHAR_REF("leftrightsquigarrow;", 0x21ad),
  CHAR_REF("leftthreetimes;", 0x22cb),
  CHAR_REF("leg;", 0x22da),
  CHAR_REF("leq;", 0x2264),
  CHAR_REF("leqq;", 0x2266),
  CHAR_REF("leqslant;", 0x2a7d),
  CHAR_REF("les;", 0x2a7d),
  CHAR_REF("lescc;", 0x2aa8),
  CHAR_REF("lesdot;", 0x2a7f),
  CHAR_REF("lesdoto;", 0x2a81),
  CHAR_REF("lesdotor;", 0x2a83),
  MULTI_CHAR_REF("lesg;", 0x22da, 0xfe00),
  CHAR_REF("lesges;", 0x2a93),
  CHAR_REF("lessapprox;", 0x2a85),
  CHAR_REF("lessdot;", 0x22d6),
  CHAR_REF("lesseqgtr;", 0x22da),
  CHAR_REF("lesseqqgtr;", 0x2a8b),
  CHAR_REF("lessgtr;", 0x2276),
  CHAR_REF("lesssim;", 0x2272),
  CHAR_REF("lfisht;", 0x297c),
  CHAR_REF("lfloor;", 0x230a),
  CHAR_REF("lfr;", 0x0001d529),
  CHAR_REF("lg;", 0x2276),
  CHAR_REF("lgE;", 0x2a91),
  CHAR_REF("lhard;", 0x21bd),
  CHAR_REF("lharu;", 0x21bc),
  CHAR_REF("lharul;", 0x296a),
  CHAR_REF("lhblk;", 0x2584),
  CHAR_REF("ljcy;", 0x0459),
  CHAR_REF("ll;", 0x226a),
  CHAR_REF("llarr;", 0x21c7),
  CHAR_REF("llcorner;", 0x231e),
  CHAR_REF("llhard;", 0x296b),
  CHAR_REF("lltri;", 0x25fa),
  CHAR_REF("lmidot;", 0x0140),
  CHAR_REF("lmoust;", 0x23b0),
  CHAR_REF("lmoustache;", 0x23b0),
  CHAR_REF("lnE;", 0x2268),
  CHAR_REF("lnap;", 0x2a89),
  CHAR_REF("lnapprox;", 0x2a89),
  CHAR_REF("lne;", 0x2a87),
  CHAR_REF("lneq;", 0x2a87),
  CHAR_REF("lneqq;", 0x2268),
  CHAR_REF("lnsim;", 0x22e6),
  CHAR_REF("loang;", 0x27ec),
  CHAR_REF("loarr;", 0x21fd),
  CHAR_REF("lobrk;", 0x27e6),
  CHAR_REF("longleftarrow;", 0x27f5),
  CHAR_REF("longleftrightarrow;", 0x27f7),
  CHAR_REF("longmapsto;", 0x27fc),
  CHAR_REF("longrightarrow;", 0x27f6),
  CHAR_REF("looparrowleft;", 0x21ab),
  CHAR_REF("looparrowright;", 0x21ac),
  CHAR_REF("lopar;", 0x2985),
  CHAR_REF("lopf;", 0x0001d55d),
  CHAR_REF("loplus;", 0x2a2d),
  CHAR_REF("lotimes;", 0x2a34),
  CHAR_REF("lowast;", 0x2217),
  CHAR_REF("lowbar;", 0x5f),
  CHAR_REF("loz;", 0x25ca),
  CHAR_REF("lozenge;", 0x25ca),
  CHAR_REF("lozf;", 0x29eb),
  CHAR_REF("lpar;", 0x28),
  CHAR_REF("lparlt;", 0x2993),
  CHAR_REF("lrarr;", 0x21c6),
  CHAR_REF("lrcorner;", 0x231f),
  CHAR_REF("lrhar;", 0x21cb),
  CHAR_REF("lrhard;", 0x296d),
  CHAR_REF("lrm;", 0x200e),
  CHAR_REF("lrtri;", 0x22bf),
  CHAR_REF("lsaquo;", 0x2039),
  CHAR_REF("lscr;", 0x0001d4c1),
  CHAR_REF("lsh;", 0x21b0),
  CHAR_REF("lsim;", 0x2272),
  CHAR_REF("lsime;", 0x2a8d),
  CHAR_REF("lsimg;", 0x2a8f),
  CHAR_REF("lsqb;", 0x5b),
  CHAR_REF("lsquo;", 0x2018),
  CHAR_REF("lsquor;", 0x201a),
  CHAR_REF("lstrok;", 0x0142),
  CHAR_REF("lt;", 0x3c),
  CHAR_REF("lt", 0x3c),
  CHAR_REF("ltcc;", 0x2aa6),
  CHAR_REF("ltcir;", 0x2a79),
  CHAR_REF("ltdot;", 0x22d6),
  CHAR_REF("lthree;", 0x22cb),
  CHAR_REF("ltimes;", 0x22c9),
  CHAR_REF("ltlarr;", 0x2976),
  CHAR_REF("ltquest;", 0x2a7b),
  CHAR_REF("ltrPar;", 0x2996),
  CHAR_REF("ltri;", 0x25c3),
  CHAR_REF("ltrie;", 0x22b4),
  CHAR_REF("ltrif;", 0x25c2),
  CHAR_REF("lurdshar;", 0x294a),
  CHAR_REF("luruhar;", 0x2966),
  MULTI_CHAR_REF("lvertneqq;", 0x2268, 0xfe00),
  MULTI_CHAR_REF("lvnE;", 0x2268, 0xfe00),
  CHAR_REF("mDDot;", 0x223a),
  CHAR_REF("macr;", 0xaf),
  CHAR_REF("macr", 0xaf),
  CHAR_REF("male;", 0x2642),
  CHAR_REF("malt;", 0x2720),
  CHAR_REF("maltese;", 0x2720),
  CHAR_REF("map;", 0x21a6),
  CHAR_REF("mapsto;", 0x21a6),
  CHAR_REF("mapstodown;", 0x21a7),
  CHAR_REF("mapstoleft;", 0x21a4),
  CHAR_REF("mapstoup;", 0x21a5),
  CHAR_REF("marker;", 0x25ae),
  CHAR_REF("mcomma;", 0x2a29),
  CHAR_REF("mcy;", 0x043c),
  CHAR_REF("mdash;", 0x2014),
  CHAR_REF("measuredangle;", 0x2221),
  CHAR_REF("mfr;", 0x0001d52a),
  CHAR_REF("mho;", 0x2127),
  CHAR_REF("micro;", 0xb5),
  CHAR_REF("micro", 0xb5),
  CHAR_REF("mid;", 0x2223),
  CHAR_REF("midast;", 0x2a),
  CHAR_REF("midcir;", 0x2af0),
  CHAR_REF("middot;", 0xb7),
  CHAR_REF("middot", 0xb7),
  CHAR_REF("minus;", 0x2212),
  CHAR_REF("minusb;", 0x229f),
  CHAR_REF("minusd;", 0x2238),
  CHAR_REF("minusdu;", 0x2a2a),
  CHAR_REF("mlcp;", 0x2adb),
  CHAR_REF("mldr;", 0x2026),
  CHAR_REF("mnplus;", 0x2213),
  CHAR_REF("models;", 0x22a7),
  CHAR_REF("mopf;", 0x0001d55e),
  CHAR_REF("mp;", 0x2213),
  CHAR_REF("mscr;", 0x0001d4c2),
  CHAR_REF("mstpos;", 0x223e),
  CHAR_REF("mu;", 0x03bc),
  CHAR_REF("multimap;", 0x22b8),
  CHAR_REF("mumap;", 0x22b8),
  MULTI_CHAR_REF("nGg;", 0x22d9, 0x0338),
  MULTI_CHAR_REF("nGt;", 0x226b, 0x20d2),
  MULTI_CHAR_REF("nGtv;", 0x226b, 0x0338),
  CHAR_REF("nLeftarrow;", 0x21cd),
  CHAR_REF("nLeftrightarrow;", 0x21ce),
  MULTI_CHAR_REF("nLl;", 0x22d8, 0x0338),
  MULTI_CHAR_REF("nLt;", 0x226a, 0x20d2),
  MULTI_CHAR_REF("nLtv;", 0x226a, 0x0338),
  CHAR_REF("nRightarrow;", 0x21cf),
  CHAR_REF("nVDash;", 0x22af),
  CHAR_REF("nVdash;", 0x22ae),
  CHAR_REF("nabla;", 0x2207),
  CHAR_REF("nacute;", 0x0144),
  MULTI_CHAR_REF("nang;", 0x2220, 0x20d2),
  CHAR_REF("nap;", 0x2249),
  MULTI_CHAR_REF("napE;", 0x2a70, 0x0338),
  MULTI_CHAR_REF("napid;", 0x224b, 0x0338),
  CHAR_REF("napos;", 0x0149),
  CHAR_REF("napprox;", 0x2249),
  CHAR_REF("natur;", 0x266e),
  CHAR_REF("natural;", 0x266e),
  CHAR_REF("naturals;", 0x2115),
  CHAR_REF("nbsp;", 0xa0),
  CHAR_REF("nbsp", 0xa0),
  MULTI_CHAR_REF("nbump;", 0x224e, 0x0338),
  MULTI_CHAR_REF("nbumpe;", 0x224f, 0x0338),
  CHAR_REF("ncap;", 0x2a43),
  CHAR_REF("ncaron;", 0x0148),
  CHAR_REF("ncedil;", 0x0146),
  CHAR_REF("ncong;", 0x2247),
  MULTI_CHAR_REF("ncongdot;", 0x2a6d, 0x0338),
  CHAR_REF("ncup;", 0x2a42),
  CHAR_REF("ncy;", 0x043d),
  CHAR_REF("ndash;", 0x2013),
  CHAR_REF("ne;", 0x2260),
  CHAR_REF("neArr;", 0x21d7),
  CHAR_REF("nearhk;", 0x2924),
  CHAR_REF("nearr;", 0x2197),
  CHAR_REF("nearrow;", 0x2197),
  MULTI_CHAR_REF("nedot;", 0x2250, 0x0338),
  CHAR_REF("nequiv;", 0x2262),
  CHAR_REF("nesear;", 0x2928),
  MULTI_CHAR_REF("nesim;", 0x2242, 0x0338),
  CHAR_REF("nexist;", 0x2204),
  CHAR_REF("nexists;", 0x2204),
  CHAR_REF("nfr;", 0x0001d52b),
  MULTI_CHAR_REF("ngE;", 0x2267, 0x0338),
  CHAR_REF("nge;", 0x2271),
  CHAR_REF("ngeq;", 0x2271),
  MULTI_CHAR_REF("ngeqq;", 0x2267, 0x0338),
  MULTI_CHAR_REF("ngeqslant;", 0x2a7e, 0x0338),
  MULTI_CHAR_REF("nges;", 0x2a7e, 0x0338),
  CHAR_REF("ngsim;", 0x2275),
  CHAR_REF("ngt;", 0x226f),
  CHAR_REF("ngtr;", 0x226f),
  CHAR_REF("nhArr;", 0x21ce),
  CHAR_REF("nharr;", 0x21ae),
  CHAR_REF("nhpar;", 0x2af2),
  CHAR_REF("ni;", 0x220b),
  CHAR_REF("nis;", 0x22fc),
  CHAR_REF("nisd;", 0x22fa),
  CHAR_REF("niv;", 0x220b),
  CHAR_REF("njcy;", 0x045a),
  CHAR_REF("nlArr;", 0x21cd),
  MULTI_CHAR_REF("nlE;", 0x2266, 0x0338),
  CHAR_REF("nlarr;", 0x219a),
  CHAR_REF("nldr;", 0x2025),
  CHAR_REF("nle;", 0x2270),
  CHAR_REF("nleftarrow;", 0x219a),
  CHAR_REF("nleftrightarrow;", 0x21ae),
  CHAR_REF("nleq;", 0x2270),
  MULTI_CHAR_REF("nleqq;", 0x2266, 0x0338),
  MULTI_CHAR_REF("nleqslant;", 0x2a7d, 0x0338),
  MULTI_CHAR_REF("nles;", 0x2a7d, 0x0338),
  CHAR_REF("nless;", 0x226e),
  CHAR_REF("nlsim;", 0x2274),
  CHAR_REF("nlt;", 0x226e),
  CHAR_REF("nltri;", 0x22ea),
  CHAR_REF("nltrie;", 0x22ec),
  CHAR_REF("nmid;", 0x2224),
  CHAR_REF("nopf;", 0x0001d55f),
  CHAR_REF("not;", 0xac),
  CHAR_REF("notin;", 0x2209),
  MULTI_CHAR_REF("notinE;", 0x22f9, 0x0338),
  MULTI_CHAR_REF("notindot;", 0x22f5, 0x0338),
  CHAR_REF("notinva;", 0x2209),
  CHAR_REF("notinvb;", 0x22f7),
  CHAR_REF("notinvc;", 0x22f6),
  CHAR_REF("notni;", 0x220c),
  CHAR_REF("notniva;", 0x220c),
  CHAR_REF("notnivb;", 0x22fe),
  CHAR_REF("notnivc;", 0x22fd),
  CHAR_REF("not", 0xac),
  CHAR_REF("npar;", 0x2226),
  CHAR_REF("nparallel;", 0x2226),
  MULTI_CHAR_REF("nparsl;", 0x2afd, 0x20e5),
  MULTI_CHAR_REF("npart;", 0x2202, 0x0338),
  CHAR_REF("npolint;", 0x2a14),
  CHAR_REF("npr;", 0x2280),
  CHAR_REF("nprcue;", 0x22e0),
  MULTI_CHAR_REF("npre;", 0x2aaf, 0x0338),
  CHAR_REF("nprec;", 0x2280),
  MULTI_CHAR_REF("npreceq;", 0x2aaf, 0x0338),
  CHAR_REF("nrArr;", 0x21cf),
  CHAR_REF("nrarr;", 0x219b),
  MULTI_CHAR_REF("nrarrc;", 0x2933, 0x0338),
  MULTI_CHAR_REF("nrarrw;", 0x219d, 0x0338),
  CHAR_REF("nrightarrow;", 0x219b),
  CHAR_REF("nrtri;", 0x22eb),
  CHAR_REF("nrtrie;", 0x22ed),
  CHAR_REF("nsc;", 0x2281),
  CHAR_REF("nsccue;", 0x22e1),
  MULTI_CHAR_REF("nsce;", 0x2ab0, 0x0338),
  CHAR_REF("nscr;", 0x0001d4c3),
  CHAR_REF("nshortmid;", 0x2224),
  CHAR_REF("nshortparallel;", 0x2226),
  CHAR_REF("nsim;", 0x2241),
  CHAR_REF("nsime;", 0x2244),
  CHAR_REF("nsimeq;", 0x2244),
  CHAR_REF("nsmid;", 0x2224),
  CHAR_REF("nspar;", 0x2226),
  CHAR_REF("nsqsube;", 0x22e2),
  CHAR_REF("nsqsupe;", 0x22e3),
  CHAR_REF("nsub;", 0x2284),
  MULTI_CHAR_REF("nsubE;", 0x2ac5, 0x0338),
  CHAR_REF("nsube;", 0x2288),
  MULTI_CHAR_REF("nsubset;", 0x2282, 0x20d2),
  CHAR_REF("nsubseteq;", 0x2288),
  MULTI_CHAR_REF("nsubseteqq;", 0x2ac5, 0x0338),
  CHAR_REF("nsucc;", 0x2281),
  MULTI_CHAR_REF("nsucceq;", 0x2ab0, 0x0338),
  CHAR_REF("nsup;", 0x2285),
  MULTI_CHAR_REF("nsupE;", 0x2ac6, 0x0338),
  CHAR_REF("nsupe;", 0x2289),
  MULTI_CHAR_REF("nsupset;", 0x2283, 0x20d2),
  CHAR_REF("nsupseteq;", 0x2289),
  MULTI_CHAR_REF("nsupseteqq;", 0x2ac6, 0x0338),
  CHAR_REF("ntgl;", 0x2279),
  CHAR_REF("ntilde;", 0xf1),
  CHAR_REF("ntilde", 0xf1),
  CHAR_REF("ntlg;", 0x2278),
  CHAR_REF("ntriangleleft;", 0x22ea),
  CHAR_REF("ntrianglelefteq;", 0x22ec),
  CHAR_REF("ntriangleright;", 0x22eb),
  CHAR_REF("ntrianglerighteq;", 0x22ed),
  CHAR_REF("nu;", 0x03bd),
  CHAR_REF("num;", 0x23),
  CHAR_REF("numero;", 0x2116),
  CHAR_REF("numsp;", 0x2007),
  CHAR_REF("nvDash;", 0x22ad),
  CHAR_REF("nvHarr;", 0x2904),
  MULTI_CHAR_REF("nvap;", 0x224d, 0x20d2),
  CHAR_REF("nvdash;", 0x22ac),
  MULTI_CHAR_REF("nvge;", 0x2265, 0x20d2),
  MULTI_CHAR_REF("nvgt;", 0x3e, 0x20d2),
  CHAR_REF("nvinfin;", 0x29de),
  CHAR_REF("nvlArr;", 0x2902),
  MULTI_CHAR_REF("nvle;", 0x2264, 0x20d2),
  MULTI_CHAR_REF("nvlt;", 0x3c, 0x20d2),
  MULTI_CHAR_REF("nvltrie;", 0x22b4, 0x20d2),
  CHAR_REF("nvrArr;", 0x2903),
  MULTI_CHAR_REF("nvrtrie;", 0x22b5, 0x20d2),
  MULTI_CHAR_REF("nvsim;", 0x223c, 0x20d2),
  CHAR_REF("nwArr;", 0x21d6),
  CHAR_REF("nwarhk;", 0x2923),
  CHAR_REF("nwarr;", 0x2196),
  CHAR_REF("nwarrow;", 0x2196),
  CHAR_REF("nwnear;", 0x2927),
  CHAR_REF("oS;", 0x24c8),
  CHAR_REF("oacute;", 0xf3),
  CHAR_REF("oacute", 0xf3),
  CHAR_REF("oast;", 0x229b),
  CHAR_REF("ocir;", 0x229a),
  CHAR_REF("ocirc;", 0xf4),
  CHAR_REF("ocirc", 0xf4),
  CHAR_REF("ocy;", 0x043e),
  CHAR_REF("odash;", 0x229d),
  CHAR_REF("odblac;", 0x0151),
  CHAR_REF("odiv;", 0x2a38),
  CHAR_REF("odot;", 0x2299),
  CHAR_REF("odsold;", 0x29bc),
  CHAR_REF("oelig;", 0x0153),
  CHAR_REF("ofcir;", 0x29bf),
  CHAR_REF("ofr;", 0x0001d52c),
  CHAR_REF("ogon;", 0x02db),
  CHAR_REF("ograve;", 0xf2),
  CHAR_REF("ograve", 0xf2),
  CHAR_REF("ogt;", 0x29c1),
  CHAR_REF("ohbar;", 0x29b5),
  CHAR_REF("ohm;", 0x03a9),
  CHAR_REF("oint;", 0x222e),
  CHAR_REF("olarr;", 0x21ba),
  CHAR_REF("olcir;", 0x29be),
  CHAR_REF("olcross;", 0x29bb),
  CHAR_REF("oline;", 0x203e),
  CHAR_REF("olt;", 0x29c0),
  CHAR_REF("omacr;", 0x014d),
  CHAR_REF("omega;", 0x03c9),
  CHAR_REF("omicron;", 0x03bf),
  CHAR_REF("omid;", 0x29b6),
  CHAR_REF("ominus;", 0x2296),
  CHAR_REF("oopf;", 0x0001d560),
  CHAR_REF("opar;", 0x29b7),
  CHAR_REF("operp;", 0x29b9),
  CHAR_REF("oplus;", 0x2295),
  CHAR_REF("or;", 0x2228),
  CHAR_REF("orarr;", 0x21bb),
  CHAR_REF("ord;", 0x2a5d),
  CHAR_REF("order;", 0x2134),
  CHAR_REF("orderof;", 0x2134),
  CHAR_REF("ordf;", 0xaa),
  CHAR_REF("ordf", 0xaa),
  CHAR_REF("ordm;", 0xba),
  CHAR_REF("ordm", 0xba),
  CHAR_REF("origof;", 0x22b6),
  CHAR_REF("oror;", 0x2a56),
  CHAR_REF("orslope;", 0x2a57),
  CHAR_REF("orv;", 0x2a5b),
  CHAR_REF("oscr;", 0x2134),
  CHAR_REF("oslash;", 0xf8),
  CHAR_REF("oslash", 0xf8),
  CHAR_REF("osol;", 0x2298),
  CHAR_REF("otilde;", 0xf5),
  CHAR_REF("otilde", 0xf5),
  CHAR_REF("otimes;", 0x2297),
  CHAR_REF("otimesas;", 0x2a36),
  CHAR_REF("ouml;", 0xf6),
  CHAR_REF("ouml", 0xf6),
  CHAR_REF("ovbar;", 0x233d),
  CHAR_REF("par;", 0x2225),
  CHAR_REF("para;", 0xb6),
  CHAR_REF("para", 0xb6),
  CHAR_REF("parallel;", 0x2225),
  CHAR_REF("parsim;", 0x2af3),
  CHAR_REF("parsl;", 0x2afd),
  CHAR_REF("part;", 0x2202),
  CHAR_REF("pcy;", 0x043f),
  CHAR_REF("percnt;", 0x25),
  CHAR_REF("period;", 0x2e),
  CHAR_REF("permil;", 0x2030),
  CHAR_REF("perp;", 0x22a5),
  CHAR_REF("pertenk;", 0x2031),
  CHAR_REF("pfr;", 0x0001d52d),
  CHAR_REF("phi;", 0x03c6),
  CHAR_REF("phiv;", 0x03d5),
  CHAR_REF("phmmat;", 0x2133),
  CHAR_REF("phone;", 0x260e),
  CHAR_REF("pi;", 0x03c0),
  CHAR_REF("pitchfork;", 0x22d4),
  CHAR_REF("piv;", 0x03d6),
  CHAR_REF("planck;", 0x210f),
  CHAR_REF("planckh;", 0x210e),
  CHAR_REF("plankv;", 0x210f),
  CHAR_REF("plus;", 0x2b),
  CHAR_REF("plusacir;", 0x2a23),
  CHAR_REF("plusb;", 0x229e),
  CHAR_REF("pluscir;", 0x2a22),
  CHAR_REF("plusdo;", 0x2214),
  CHAR_REF("plusdu;", 0x2a25),
  CHAR_REF("pluse;", 0x2a72),
  CHAR_REF("plusmn;", 0xb1),
  CHAR_REF("plusmn", 0xb1),
  CHAR_REF("plussim;", 0x2a26),
  CHAR_REF("plustwo;", 0x2a27),
  CHAR_REF("pm;", 0xb1),
  CHAR_REF("pointint;", 0x2a15),
  CHAR_REF("popf;", 0x0001d561),
  CHAR_REF("pound;", 0xa3),
  CHAR_REF("pound", 0xa3),
  CHAR_REF("pr;", 0x227a),
  CHAR_REF("prE;", 0x2ab3),
  CHAR_REF("prap;", 0x2ab7),
  CHAR_REF("prcue;", 0x227c),
  CHAR_REF("pre;", 0x2aaf),
  CHAR_REF("prec;", 0x227a),
  CHAR_REF("precapprox;", 0x2ab7),
  CHAR_REF("preccurlyeq;", 0x227c),
  CHAR_REF("preceq;", 0x2aaf),
  CHAR_REF("precnapprox;", 0x2ab9),
  CHAR_REF("precneqq;", 0x2ab5),
  CHAR_REF("precnsim;", 0x22e8),
  CHAR_REF("precsim;", 0x227e),
  CHAR_REF("prime;", 0x2032),
  CHAR_REF("primes;", 0x2119),
  CHAR_REF("prnE;", 0x2ab5),
  CHAR_REF("prnap;", 0x2ab9),
  CHAR_REF("prnsim;", 0x22e8),
  CHAR_REF("prod;", 0x220f),
  CHAR_REF("profalar;", 0x232e),
  CHAR_REF("profline;", 0x2312),
  CHAR_REF("profsurf;", 0x2313),
  CHAR_REF("prop;", 0x221d),
  CHAR_REF("propto;", 0x221d),
  CHAR_REF("prsim;", 0x227e),
  CHAR_REF("prurel;", 0x22b0),
  CHAR_REF("pscr;", 0x0001d4c5),
  CHAR_REF("psi;", 0x03c8),
  CHAR_REF("puncsp;", 0x2008),
  CHAR_REF("qfr;", 0x0001d52e),
  CHAR_REF("qint;", 0x2a0c),
  CHAR_REF("qopf;", 0x0001d562),
  CHAR_REF("qprime;", 0x2057),
  CHAR_REF("qscr;", 0x0001d4c6),
  CHAR_REF("quaternions;", 0x210d),
  CHAR_REF("quatint;", 0x2a16),
  CHAR_REF("quest;", 0x3f),
  CHAR_REF("questeq;", 0x225f),
  CHAR_REF("quot;", 0x22),
  CHAR_REF("quot", 0x22),
  CHAR_REF("rAarr;", 0x21db),
  CHAR_REF("rArr;", 0x21d2),
  CHAR_REF("rAtail;", 0x291c),
  CHAR_REF("rBarr;", 0x290f),
  CHAR_REF("rHar;", 0x2964),
  MULTI_CHAR_REF("race;", 0x223d, 0x0331),
  CHAR_REF("racute;", 0x0155),
  CHAR_REF("radic;", 0x221a),
  CHAR_REF("raemptyv;", 0x29b3),
  CHAR_REF("rang;", 0x27e9),
  CHAR_REF("rangd;", 0x2992),
  CHAR_REF("range;", 0x29a5),
  CHAR_REF("rangle;", 0x27e9),
  CHAR_REF("raquo;", 0xbb),
  CHAR_REF("raquo", 0xbb),
  CHAR_REF("rarr;", 0x2192),
  CHAR_REF("rarrap;", 0x2975),
  CHAR_REF("rarrb;", 0x21e5),
  CHAR_REF("rarrbfs;", 0x2920),
  CHAR_REF("rarrc;", 0x2933),
  CHAR_REF("rarrfs;", 0x291e),
  CHAR_REF("rarrhk;", 0x21aa),
  CHAR_REF("rarrlp;", 0x21ac),
  CHAR_REF("rarrpl;", 0x2945),
  CHAR_REF("rarrsim;", 0x2974),
  CHAR_REF("rarrtl;", 0x21a3),
  CHAR_REF("rarrw;", 0x219d),
  CHAR_REF("ratail;", 0x291a),
  CHAR_REF("ratio;", 0x2236),
  CHAR_REF("rationals;", 0x211a),
  CHAR_REF("rbarr;", 0x290d),
  CHAR_REF("rbbrk;", 0x2773),
  CHAR_REF("rbrace;", 0x7d),
  CHAR_REF("rbrack;", 0x5d),
  CHAR_REF("rbrke;", 0x298c),
  CHAR_REF("rbrksld;", 0x298e),
  CHAR_REF("rbrkslu;", 0x2990),
  CHAR_REF("rcaron;", 0x0159),
  CHAR_REF("rcedil;", 0x0157),
  CHAR_REF("rceil;", 0x2309),
  CHAR_REF("rcub;", 0x7d),
  CHAR_REF("rcy;", 0x0440),
  CHAR_REF("rdca;", 0x2937),
  CHAR_REF("rdldhar;", 0x2969),
  CHAR_REF("rdquo;", 0x201d),
  CHAR_REF("rdquor;", 0x201d),
  CHAR_REF("rdsh;", 0x21b3),
  CHAR_REF("real;", 0x211c),
  CHAR_REF("realine;", 0x211b),
  CHAR_REF("realpart;", 0x211c),
  CHAR_REF("reals;", 0x211d),
  CHAR_REF("rect;", 0x25ad),
  CHAR_REF("reg;", 0xae),
  CHAR_REF("reg", 0xae),
  CHAR_REF("rfisht;", 0x297d),
  CHAR_REF("rfloor;", 0x230b),
  CHAR_REF("rfr;", 0x0001d52f),
  CHAR_REF("rhard;", 0x21c1),
  CHAR_REF("rharu;", 0x21c0),
  CHAR_REF("rharul;", 0x296c),
  CHAR_REF("rho;", 0x03c1),
  CHAR_REF("rhov;", 0x03f1),
  CHAR_REF("rightarrow;", 0x2192),
  CHAR_REF("rightarrowtail;", 0x21a3),
  CHAR_REF("rightharpoondown;", 0x21c1),
  CHAR_REF("rightharpoonup;", 0x21c0),
  CHAR_REF("rightleftarrows;", 0x21c4),
  CHAR_REF("rightleftharpoons;", 0x21cc),
  CHAR_REF("rightrightarrows;", 0x21c9),
  CHAR_REF("rightsquigarrow;", 0x219d),
  CHAR_REF("rightthreetimes;", 0x22cc),
  CHAR_REF("ring;", 0x02da),
  CHAR_REF("risingdotseq;", 0x2253),
  CHAR_REF("rlarr;", 0x21c4),
  CHAR_REF("rlhar;", 0x21cc),
  CHAR_REF("rlm;", 0x200f),
  CHAR_REF("rmoust;", 0x23b1),
  CHAR_REF("rmoustache;", 0x23b1),
  CHAR_REF("rnmid;", 0x2aee),
  CHAR_REF("roang;", 0x27ed),
  CHAR_REF("roarr;", 0x21fe),
  CHAR_REF("robrk;", 0x27e7),
  CHAR_REF("ropar;", 0x2986),
  CHAR_REF("ropf;", 0x0001d563),
  CHAR_REF("roplus;", 0x2a2e),
  CHAR_REF("rotimes;", 0x2a35),
  CHAR_REF("rpar;", 0x29),
  CHAR_REF("rpargt;", 0x2994),
  CHAR_REF("rppolint;", 0x2a12),
  CHAR_REF("rrarr;", 0x21c9),
  CHAR_REF("rsaquo;", 0x203a),
  CHAR_REF("rscr;", 0x0001d4c7),
  CHAR_REF("rsh;", 0x21b1),
  CHAR_REF("rsqb;", 0x5d),
  CHAR_REF("rsquo;", 0x2019),
  CHAR_REF("rsquor;", 0x2019),
  CHAR_REF("rthree;", 0x22cc),
  CHAR_REF("rtimes;", 0x22ca),
  CHAR_REF("rtri;", 0x25b9),
  CHAR_REF("rtrie;", 0x22b5),
  CHAR_REF("rtrif;", 0x25b8),
  CHAR_REF("rtriltri;", 0x29ce),
  CHAR_REF("ruluhar;", 0x2968),
  CHAR_REF("rx;", 0x211e),
  CHAR_REF("sacute;", 0x015b),
  CHAR_REF("sbquo;", 0x201a),
  CHAR_REF("sc;", 0x227b),
  CHAR_REF("scE;", 0x2ab4),
  CHAR_REF("scap;", 0x2ab8),
  CHAR_REF("scaron;", 0x0161),
  CHAR_REF("sccue;", 0x227d),
  CHAR_REF("sce;", 0x2ab0),
  CHAR_REF("scedil;", 0x015f),
  CHAR_REF("scirc;", 0x015d),
  CHAR_REF("scnE;", 0x2ab6),
  CHAR_REF("scnap;", 0x2aba),
  CHAR_REF("scnsim;", 0x22e9),
  CHAR_REF("scpolint;", 0x2a13),
  CHAR_REF("scsim;", 0x227f),
  CHAR_REF("scy;", 0x0441),
  CHAR_REF("sdot;", 0x22c5),
  CHAR_REF("sdotb;", 0x22a1),
  CHAR_REF("sdote;", 0x2a66),
  CHAR_REF("seArr;", 0x21d8),
  CHAR_REF("searhk;", 0x2925),
  CHAR_REF("searr;", 0x2198),
  CHAR_REF("searrow;", 0x2198),
  CHAR_REF("sect;", 0xa7),
  CHAR_REF("sect", 0xa7),
  CHAR_REF("semi;", 0x3b),
  CHAR_REF("seswar;", 0x2929),
  CHAR_REF("setminus;", 0x2216),
  CHAR_REF("setmn;", 0x2216),
  CHAR_REF("sext;", 0x2736),
  CHAR_REF("sfr;", 0x0001d530),
  CHAR_REF("sfrown;", 0x2322),
  CHAR_REF("sharp;", 0x266f),
  CHAR_REF("shchcy;", 0x0449),
  CHAR_REF("shcy;", 0x0448),
  CHAR_REF("shortmid;", 0x2223),
  CHAR_REF("shortparallel;", 0x2225),
  CHAR_REF("shy;", 0xad),
  CHAR_REF("shy", 0xad),
  CHAR_REF("sigma;", 0x03c3),
  CHAR_REF("sigmaf;", 0x03c2),
  CHAR_REF("sigmav;", 0x03c2),
  CHAR_REF("sim;", 0x223c),
  CHAR_REF("simdot;", 0x2a6a),
  CHAR_REF("sime;", 0x2243),
  CHAR_REF("simeq;", 0x2243),
  CHAR_REF("simg;", 0x2a9e),
  CHAR_REF("simgE;", 0x2aa0),
  CHAR_REF("siml;", 0x2a9d),
  CHAR_REF("simlE;", 0x2a9f),
  CHAR_REF("simne;", 0x2246),
  CHAR_REF("simplus;", 0x2a24),
  CHAR_REF("simrarr;", 0x2972),
  CHAR_REF("slarr;", 0x2190),
  CHAR_REF("smallsetminus;", 0x2216),
  CHAR_REF("smashp;", 0x2a33),
  CHAR_REF("smeparsl;", 0x29e4),
  CHAR_REF("smid;", 0x2223),
  CHAR_REF("smile;", 0x2323),
  CHAR_REF("smt;", 0x2aaa),
  CHAR_REF("smte;", 0x2aac),
  MULTI_CHAR_REF("smtes;", 0x2aac, 0xfe00),
  CHAR_REF("softcy;", 0x044c),
  CHAR_REF("sol;", 0x2f),
  CHAR_REF("solb;", 0x29c4),
  CHAR_REF("solbar;", 0x233f),
  CHAR_REF("sopf;", 0x0001d564),
  CHAR_REF("spades;", 0x2660),
  CHAR_REF("spadesuit;", 0x2660),
  CHAR_REF("spar;", 0x2225),
  CHAR_REF("sqcap;", 0x2293),
  MULTI_CHAR_REF("sqcaps;", 0x2293, 0xfe00),
  CHAR_REF("sqcup;", 0x2294),
  MULTI_CHAR_REF("sqcups;", 0x2294, 0xfe00),
  CHAR_REF("sqsub;", 0x228f),
  CHAR_REF("sqsube;", 0x2291),
  CHAR_REF("sqsubset;", 0x228f),
  CHAR_REF("sqsubseteq;", 0x2291),
  CHAR_REF("sqsup;", 0x2290),
  CHAR_REF("sqsupe;", 0x2292),
  CHAR_REF("sqsupset;", 0x2290),
  CHAR_REF("sqsupseteq;", 0x2292),
  CHAR_REF("squ;", 0x25a1),
  CHAR_REF("square;", 0x25a1),
  CHAR_REF("squarf;", 0x25aa),
  CHAR_REF("squf;", 0x25aa),
  CHAR_REF("srarr;", 0x2192),
  CHAR_REF("sscr;", 0x0001d4c8),
  CHAR_REF("ssetmn;", 0x2216),
  CHAR_REF("ssmile;", 0x2323),
  CHAR_REF("sstarf;", 0x22c6),
  CHAR_REF("star;", 0x2606),
  CHAR_REF("starf;", 0x2605),
  CHAR_REF("straightepsilon;", 0x03f5),
  CHAR_REF("straightphi;", 0x03d5),
  CHAR_REF("strns;", 0xaf),
  CHAR_REF("sub;", 0x2282),
  CHAR_REF("subE;", 0x2ac5),
  CHAR_REF("subdot;", 0x2abd),
  CHAR_REF("sube;", 0x2286),
  CHAR_REF("subedot;", 0x2ac3),
  CHAR_REF("submult;", 0x2ac1),
  CHAR_REF("subnE;", 0x2acb),
  CHAR_REF("subne;", 0x228a),
  CHAR_REF("subplus;", 0x2abf),
  CHAR_REF("subrarr;", 0x2979),
  CHAR_REF("subset;", 0x2282),
  CHAR_REF("subseteq;", 0x2286),
  CHAR_REF("subseteqq;", 0x2ac5),
  CHAR_REF("subsetneq;", 0x228a),
  CHAR_REF("subsetneqq;", 0x2acb),
  CHAR_REF("subsim;", 0x2ac7),
  CHAR_REF("subsub;", 0x2ad5),
  CHAR_REF("subsup;", 0x2ad3),
  CHAR_REF("succ;", 0x227b),
  CHAR_REF("succapprox;", 0x2ab8),
  CHAR_REF("succcurlyeq;", 0x227d),
  CHAR_REF("succeq;", 0x2ab0),
  CHAR_REF("succnapprox;", 0x2aba),
  CHAR_REF("succneqq;", 0x2ab6),
  CHAR_REF("succnsim;", 0x22e9),
  CHAR_REF("succsim;", 0x227f),
  CHAR_REF("sum;", 0x2211),
  CHAR_REF("sung;", 0x266a),
  CHAR_REF("sup1;", 0xb9),
  CHAR_REF("sup1", 0xb9),
  CHAR_REF("sup2;", 0xb2),
  CHAR_REF("sup2", 0xb2),
  CHAR_REF("sup3;", 0xb3),
  CHAR_REF("sup3", 0xb3),
  CHAR_REF("sup;", 0x2283),
  CHAR_REF("supE;", 0x2ac6),
  CHAR_REF("supdot;", 0x2abe),
  CHAR_REF("supdsub;", 0x2ad8),
  CHAR_REF("supe;", 0x2287),
  CHAR_REF("supedot;", 0x2ac4),
  CHAR_REF("suphsol;", 0x27c9),
  CHAR_REF("suphsub;", 0x2ad7),
  CHAR_REF("suplarr;", 0x297b),
  CHAR_REF("supmult;", 0x2ac2),
  CHAR_REF("supnE;", 0x2acc),
  CHAR_REF("supne;", 0x228b),
  CHAR_REF("supplus;", 0x2ac0),
  CHAR_REF("supset;", 0x2283),
  CHAR_REF("supseteq;", 0x2287),
  CHAR_REF("supseteqq;", 0x2ac6),
  CHAR_REF("supsetneq;", 0x228b),
  CHAR_REF("supsetneqq;", 0x2acc),
  CHAR_REF("supsim;", 0x2ac8),
  CHAR_REF("supsub;", 0x2ad4),
  CHAR_REF("supsup;", 0x2ad6),
  CHAR_REF("swArr;", 0x21d9),
  CHAR_REF("swarhk;", 0x2926),
  CHAR_REF("swarr;", 0x2199),
  CHAR_REF("swarrow;", 0x2199),
  CHAR_REF("swnwar;", 0x292a),
  CHAR_REF("szlig;", 0xdf),
  CHAR_REF("szlig", 0xdf),
  CHAR_REF("target;", 0x2316),
  CHAR_REF("tau;", 0x03c4),
  CHAR_REF("tbrk;", 0x23b4),
  CHAR_REF("tcaron;", 0x0165),
  CHAR_REF("tcedil;", 0x0163),
  CHAR_REF("tcy;", 0x0442),
  CHAR_REF("tdot;", 0x20db),
  CHAR_REF("telrec;", 0x2315),
  CHAR_REF("tfr;", 0x0001d531),
  CHAR_REF("there4;", 0x2234),
  CHAR_REF("therefore;", 0x2234),
  CHAR_REF("theta;", 0x03b8),
  CHAR_REF("thetasym;", 0x03d1),
  CHAR_REF("thetav;", 0x03d1),
  CHAR_REF("thickapprox;", 0x2248),
  CHAR_REF("thicksim;", 0x223c),
  CHAR_REF("thinsp;", 0x2009),
  CHAR_REF("thkap;", 0x2248),
  CHAR_REF("thksim;", 0x223c),
  CHAR_REF("thorn;", 0xfe),
  CHAR_REF("thorn", 0xfe),
  CHAR_REF("tilde;", 0x02dc),
  CHAR_REF("times;", 0xd7),
  CHAR_REF("times", 0xd7),
  CHAR_REF("timesb;", 0x22a0),
  CHAR_REF("timesbar;", 0x2a31),
  CHAR_REF("timesd;", 0x2a30),
  CHAR_REF("tint;", 0x222d),
  CHAR_REF("toea;", 0x2928),
  CHAR_REF("top;", 0x22a4),
  CHAR_REF("topbot;", 0x2336),
  CHAR_REF("topcir;", 0x2af1),
  CHAR_REF("topf;", 0x0001d565),
  CHAR_REF("topfork;", 0x2ada),
  CHAR_REF("tosa;", 0x2929),
  CHAR_REF("tprime;", 0x2034),
  CHAR_REF("trade;", 0x2122),
  CHAR_REF("triangle;", 0x25b5),
  CHAR_REF("triangledown;", 0x25bf),
  CHAR_REF("triangleleft;", 0x25c3),
  CHAR_REF("trianglelefteq;", 0x22b4),
  CHAR_REF("triangleq;", 0x225c),
  CHAR_REF("triangleright;", 0x25b9),
  CHAR_REF("trianglerighteq;", 0x22b5),
  CHAR_REF("tridot;", 0x25ec),
  CHAR_REF("trie;", 0x225c),
  CHAR_REF("triminus;", 0x2a3a),
  CHAR_REF("triplus;", 0x2a39),
  CHAR_REF("trisb;", 0x29cd),
  CHAR_REF("tritime;", 0x2a3b),
  CHAR_REF("trpezium;", 0x23e2),
  CHAR_REF("tscr;", 0x0001d4c9),
  CHAR_REF("tscy;", 0x0446),
  CHAR_REF("tshcy;", 0x045b),
  CHAR_REF("tstrok;", 0x0167),
  CHAR_REF("twixt;", 0x226c),
  CHAR_REF("twoheadleftarrow;", 0x219e),
  CHAR_REF("twoheadrightarrow;", 0x21a0),
  CHAR_REF("uArr;", 0x21d1),
  CHAR_REF("uHar;", 0x2963),
  CHAR_REF("uacute;", 0xfa),
  CHAR_REF("uacute", 0xfa),
  CHAR_REF("uarr;", 0x2191),
  CHAR_REF("ubrcy;", 0x045e),
  CHAR_REF("ubreve;", 0x016d),
  CHAR_REF("ucirc;", 0xfb),
  CHAR_REF("ucirc", 0xfb),
  CHAR_REF("ucy;", 0x0443),
  CHAR_REF("udarr;", 0x21c5),
  CHAR_REF("udblac;", 0x0171),
  CHAR_REF("udhar;", 0x296e),
  CHAR_REF("ufisht;", 0x297e),
  CHAR_REF("ufr;", 0x0001d532),
  CHAR_REF("ugrave;", 0xf9),
  CHAR_REF("ugrave", 0xf9),
  CHAR_REF("uharl;", 0x21bf),
  CHAR_REF("uharr;", 0x21be),
  CHAR_REF("uhblk;", 0x2580),
  CHAR_REF("ulcorn;", 0x231c),
  CHAR_REF("ulcorner;", 0x231c),
  CHAR_REF("ulcrop;", 0x230f),
  CHAR_REF("ultri;", 0x25f8),
  CHAR_REF("umacr;", 0x016b),
  CHAR_REF("uml;", 0xa8),
  CHAR_REF("uml", 0xa8),
  CHAR_REF("uogon;", 0x0173),
  CHAR_REF("uopf;", 0x0001d566),
  CHAR_REF("uparrow;", 0x2191),
  CHAR_REF("updownarrow;", 0x2195),
  CHAR_REF("upharpoonleft;", 0x21bf),
  CHAR_REF("upharpoonright;", 0x21be),
  CHAR_REF("uplus;", 0x228e),
  CHAR_REF("upsi;", 0x03c5),
  CHAR_REF("upsih;", 0x03d2),
  CHAR_REF("upsilon;", 0x03c5),
  CHAR_REF("upuparrows;", 0x21c8),
  CHAR_REF("urcorn;", 0x231d),
  CHAR_REF("urcorner;", 0x231d),
  CHAR_REF("urcrop;", 0x230e),
  CHAR_REF("uring;", 0x016f),
  CHAR_REF("urtri;", 0x25f9),
  CHAR_REF("uscr;", 0x0001d4ca),
  CHAR_REF("utdot;", 0x22f0),
  CHAR_REF("utilde;", 0x0169),
  CHAR_REF("utri;", 0x25b5),
  CHAR_REF("utrif;", 0x25b4),
  CHAR_REF("uuarr;", 0x21c8),
  CHAR_REF("uuml;", 0xfc),
  CHAR_REF("uuml", 0xfc),
  CHAR_REF("uwangle;", 0x29a7),
  CHAR_REF("vArr;", 0x21d5),
  CHAR_REF("vBar;", 0x2ae8),
  CHAR_REF("vBarv;", 0x2ae9),
  CHAR_REF("vDash;", 0x22a8),
  CHAR_REF("vangrt;", 0x299c),
  CHAR_REF("varepsilon;", 0x03f5),
  CHAR_REF("varkappa;", 0x03f0),
  CHAR_REF("varnothing;", 0x2205),
  CHAR_REF("varphi;", 0x03d5),
  CHAR_REF("varpi;", 0x03d6),
  CHAR_REF("varpropto;", 0x221d),
  CHAR_REF("varr;", 0x2195),
  CHAR_REF("varrho;", 0x03f1),
  CHAR_REF("varsigma;", 0x03c2),
  MULTI_CHAR_REF("varsubsetneq;", 0x228a, 0xfe00),
  MULTI_CHAR_REF("varsubsetneqq;", 0x2acb, 0xfe00),
  MULTI_CHAR_REF("varsupsetneq;", 0x228b, 0xfe00),
  MULTI_CHAR_REF("varsupsetneqq;", 0x2acc, 0xfe00),
  CHAR_REF("vartheta;", 0x03d1),
  CHAR_REF("vartriangleleft;", 0x22b2),
  CHAR_REF("vartriangleright;", 0x22b3),
  CHAR_REF("vcy;", 0x0432),
  CHAR_REF("vdash;", 0x22a2),
  CHAR_REF("vee;", 0x2228),
  CHAR_REF("veebar;", 0x22bb),
  CHAR_REF("veeeq;", 0x225a),
  CHAR_REF("vellip;", 0x22ee),
  CHAR_REF("verbar;", 0x7c),
  CHAR_REF("vert;", 0x7c),
  CHAR_REF("vfr;", 0x0001d533),
  CHAR_REF("vltri;", 0x22b2),
  MULTI_CHAR_REF("vnsub;", 0x2282, 0x20d2),
  MULTI_CHAR_REF("vnsup;", 0x2283, 0x20d2),
  CHAR_REF("vopf;", 0x0001d567),
  CHAR_REF("vprop;", 0x221d),
  CHAR_REF("vrtri;", 0x22b3),
  CHAR_REF("vscr;", 0x0001d4cb),
  MULTI_CHAR_REF("vsubnE;", 0x2acb, 0xfe00),
  MULTI_CHAR_REF("vsubne;", 0x228a, 0xfe00),
  MULTI_CHAR_REF("vsupnE;", 0x2acc, 0xfe00),
  MULTI_CHAR_REF("vsupne;", 0x228b, 0xfe00),
  CHAR_REF("vzigzag;", 0x299a),
  CHAR_REF("wcirc;", 0x0175),
  CHAR_REF("wedbar;", 0x2a5f),
  CHAR_REF("wedge;", 0x2227),
  CHAR_REF("wedgeq;", 0x2259),
  CHAR_REF("weierp;", 0x2118),
  CHAR_REF("wfr;", 0x0001d534),
  CHAR_REF("wopf;", 0x0001d568),
  CHAR_REF("wp;", 0x2118),
  CHAR_REF("wr;", 0x2240),
  CHAR_REF("wreath;", 0x2240),
  CHAR_REF("wscr;", 0x0001d4cc),
  CHAR_REF("xcap;", 0x22c2),
  CHAR_REF("xcirc;", 0x25ef),
  CHAR_REF("xcup;", 0x22c3),
  CHAR_REF("xdtri;", 0x25bd),
  CHAR_REF("xfr;", 0x0001d535),
  CHAR_REF("xhArr;", 0x27fa),
  CHAR_REF("xharr;", 0x27f7),
  CHAR_REF("xi;", 0x03be),
  CHAR_REF("xlArr;", 0x27f8),
  CHAR_REF("xlarr;", 0x27f5),
  CHAR_REF("xmap;", 0x27fc),
  CHAR_REF("xnis;", 0x22fb),
  CHAR_REF("xodot;", 0x2a00),
  CHAR_REF("xopf;", 0x0001d569),
  CHAR_REF("xoplus;", 0x2a01),
  CHAR_REF("xotime;", 0x2a02),
  CHAR_REF("xrArr;", 0x27f9),
  CHAR_REF("xrarr;", 0x27f6),
  CHAR_REF("xscr;", 0x0001d4cd),
  CHAR_REF("xsqcup;", 0x2a06),
  CHAR_REF("xuplus;", 0x2a04),
  CHAR_REF("xutri;", 0x25b3),
  CHAR_REF("xvee;", 0x22c1),
  CHAR_REF("xwedge;", 0x22c0),
  CHAR_REF("yacute;", 0xfd),
  CHAR_REF("yacute", 0xfd),
  CHAR_REF("yacy;", 0x044f),
  CHAR_REF("ycirc;", 0x0177),
  CHAR_REF("ycy;", 0x044b),
  CHAR_REF("yen;", 0xa5),
  CHAR_REF("yen", 0xa5),
  CHAR_REF("yfr;", 0x0001d536),
  CHAR_REF("yicy;", 0x0457),
  CHAR_REF("yopf;", 0x0001d56a),
  CHAR_REF("yscr;", 0x0001d4ce),
  CHAR_REF("yucy;", 0x044e),
  CHAR_REF("yuml;", 0xff),
  CHAR_REF("yuml", 0xff),
  CHAR_REF("zacute;", 0x017a),
  CHAR_REF("zcaron;", 0x017e),
  CHAR_REF("zcy;", 0x0437),
  CHAR_REF("zdot;", 0x017c),
  CHAR_REF("zeetrf;", 0x2128),
  CHAR_REF("zeta;", 0x03b6),
  CHAR_REF("zfr;", 0x0001d537),
  CHAR_REF("zhcy;", 0x0436),
  CHAR_REF("zigrarr;", 0x21dd),
  CHAR_REF("zopf;", 0x0001d56b),
  CHAR_REF("zscr;", 0x0001d4cf),
  CHAR_REF("zwj;", 0x200d),
  CHAR_REF("zwnj;", 0x200c),
  // Terminator.
  CHAR_REF("", -1)
};

// Table of replacement characters.  The spec specifies that any occurrence of
// the first character should be replaced by the second character, and a parse
// error recorded.
typedef struct {
  int from_char;
  int to_char;
} CharReplacement;

static const CharReplacement kCharReplacements[] = {
  { 0x00, 0xfffd },
  { 0x0d, 0x000d },
  { 0x80, 0x20ac },
  { 0x81, 0x0081 },
  { 0x82, 0x201A },
  { 0x83, 0x0192 },
  { 0x84, 0x201E },
  { 0x85, 0x2026 },
  { 0x86, 0x2020 },
  { 0x87, 0x2021 },
  { 0x88, 0x02C6 },
  { 0x89, 0x2030 },
  { 0x8A, 0x0160 },
  { 0x8B, 0x2039 },
  { 0x8C, 0x0152 },
  { 0x8D, 0x008D },
  { 0x8E, 0x017D },
  { 0x8F, 0x008F },
  { 0x90, 0x0090 },
  { 0x91, 0x2018 },
  { 0x92, 0x2019 },
  { 0x93, 0x201C },
  { 0x94, 0x201D },
  { 0x95, 0x2022 },
  { 0x96, 0x2013 },
  { 0x97, 0x2014 },
  { 0x98, 0x02DC },
  { 0x99, 0x2122 },
  { 0x9A, 0x0161 },
  { 0x9B, 0x203A },
  { 0x9C, 0x0153 },
  { 0x9D, 0x009D },
  { 0x9E, 0x017E },
  { 0x9F, 0x0178 },
  // Terminator.
  { -1, -1 }
};

static int parse_digit(int c, bool allow_hex) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (allow_hex && c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (allow_hex && c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

static void add_no_digit_error(
    struct GumboInternalParser* parser, Utf8Iterator* input) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = GUMBO_ERR_NUMERIC_CHAR_REF_NO_DIGITS;
}

static void add_codepoint_error(
    struct GumboInternalParser* parser, Utf8Iterator* input,
    GumboErrorType type, int codepoint) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = type;
  error->v.codepoint = codepoint;
}

static void add_named_reference_error(
    struct GumboInternalParser* parser, Utf8Iterator* input,
    GumboErrorType type, GumboStringPiece text) {
  GumboError* error = gumbo_add_error(parser);
  if (!error) {
    return;
  }
  utf8iterator_fill_error_at_mark(input, error);
  error->type = type;
  error->v.text = text;
}

static int maybe_replace_codepoint(int codepoint) {
  for (int i = 0; kCharReplacements[i].from_char != -1; ++i) {
    if (kCharReplacements[i].from_char == codepoint) {
      return kCharReplacements[i].to_char;
    }
  }
  return -1;
}

static bool consume_numeric_ref(
    struct GumboInternalParser* parser, Utf8Iterator* input, int* output) {
  utf8iterator_next(input);
  bool is_hex = false;
  int c = utf8iterator_current(input);
  if (c == 'x' || c == 'X') {
    is_hex = true;
    utf8iterator_next(input);
    c = utf8iterator_current(input);
  }

  int digit = parse_digit(c, is_hex);
  if (digit == -1) {
    // First digit was invalid; add a parse error and return.
    add_no_digit_error(parser, input);
    utf8iterator_reset(input);
    *output = kGumboNoChar;
    return false;
  }

  int codepoint = 0;
  bool status = true;
  do {
    codepoint = (codepoint * (is_hex ? 16 : 10)) + digit;
    utf8iterator_next(input);
    digit = parse_digit(utf8iterator_current(input), is_hex);
  } while (digit != -1);

  if (utf8iterator_current(input) != ';') {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_WITHOUT_SEMICOLON, codepoint);
    status = false;
  } else {
    utf8iterator_next(input);
  }

  int replacement = maybe_replace_codepoint(codepoint);
  if (replacement != -1) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    *output = replacement;
    return false;
  }

  if ((codepoint >= 0xd800 && codepoint <= 0xdfff) || codepoint > 0x10ffff) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    *output = 0xfffd;
    return false;
  }

  if (utf8_is_invalid_code_point(codepoint) || codepoint == 0xb) {
    add_codepoint_error(
        parser, input, GUMBO_ERR_NUMERIC_CHAR_REF_INVALID, codepoint);
    status = false;
    // But return it anyway, per spec.
  }
  *output = codepoint;
  return status;
}

static bool is_legal_attribute_char_next(Utf8Iterator* input) {
  int c = utf8iterator_current(input);
  return c == '=' || isalnum(c);
}

static bool maybe_add_invalid_named_reference(
    struct GumboInternalParser* parser, Utf8Iterator* input) {
  // The iterator will always be reset in this code path, so we don't need to
  // worry about consuming characters.
  const char* start = utf8iterator_get_char_pointer(input);
  int c = utf8iterator_current(input);
  while ((c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9')) {
    utf8iterator_next(input);
    c = utf8iterator_current(input);
  }
  if (c == ';') {
    GumboStringPiece bad_ref;
    bad_ref.data = start;
    bad_ref.length = utf8iterator_get_char_pointer(input) - start;
    add_named_reference_error(
        parser, input, GUMBO_ERR_NAMED_CHAR_REF_INVALID, bad_ref);
    return false;
  }
  return true;
}

%%{
machine char_ref;

valid_named_ref := |*
  'AElig' => { output->first = 0xc6; };
  'AMP;' => { output->first = 0x26; };
  'AMP' => { output->first = 0x26; };
  'Aacute;' => { output->first = 0xc1; };
  'Aacute' => { output->first = 0xc1; };
  'Abreve;' => { output->first = 0x0102; };
  'Acirc;' => { output->first = 0xc2; };
  'Acirc' => { output->first = 0xc2; };
  'Acy;' => { output->first = 0x0410; };
  'Afr;' => { output->first = 0x0001d504; };
  'Agrave;' => { output->first = 0xc0; };
  'Agrave' => { output->first = 0xc0; };
  'Alpha;' => { output->first = 0x0391; };
  'Amacr;' => { output->first = 0x0100; };
  'And;' => { output->first = 0x2a53; };
  'Aogon;' => { output->first = 0x0104; };
  'Aopf;' => { output->first = 0x0001d538; };
  'ApplyFunction;' => { output->first = 0x2061; };
  'Aring;' => { output->first = 0xc5; };
  'Aring' => { output->first = 0xc5; };
  'Ascr;' => { output->first = 0x0001d49c; };
  'Assign;' => { output->first = 0x2254; };
  'Atilde;' => { output->first = 0xc3; };
  'Atilde' => { output->first = 0xc3; };
  'Auml;' => { output->first = 0xc4; };
  'Auml' => { output->first = 0xc4; };
  'Backslash;' => { output->first = 0x2216; };
  'Barv;' => { output->first = 0x2ae7; };
  'Barwed;' => { output->first = 0x2306; };
  'Bcy;' => { output->first = 0x0411; };
  'Because;' => { output->first = 0x2235; };
  'Bernoullis;' => { output->first = 0x212c; };
  'Beta;' => { output->first = 0x0392; };
  'Bfr;' => { output->first = 0x0001d505; };
  'Bopf;' => { output->first = 0x0001d539; };
  'Breve;' => { output->first = 0x02d8; };
  'Bscr;' => { output->first = 0x212c; };
  'Bumpeq;' => { output->first = 0x224e; };
  'CHcy;' => { output->first = 0x0427; };
  'COPY;' => { output->first = 0xa9; };
  'COPY' => { output->first = 0xa9; };
  'Cacute;' => { output->first = 0x0106; };
  'Cap;' => { output->first = 0x22d2; };
  'CapitalDifferentialD;' => { output->first = 0x2145; };
  'Cayleys;' => { output->first = 0x212d; };
  'Ccaron;' => { output->first = 0x010c; };
  'Ccedil;' => { output->first = 0xc7; };
  'Ccedil' => { output->first = 0xc7; };
  'Ccirc;' => { output->first = 0x0108; };
  'Cconint;' => { output->first = 0x2230; };
  'Cdot;' => { output->first = 0x010a; };
  'Cedilla;' => { output->first = 0xb8; };
  'CenterDot;' => { output->first = 0xb7; };
  'Cfr;' => { output->first = 0x212d; };
  'Chi;' => { output->first = 0x03a7; };
  'CircleDot;' => { output->first = 0x2299; };
  'CircleMinus;' => { output->first = 0x2296; };
  'CirclePlus;' => { output->first = 0x2295; };
  'CircleTimes;' => { output->first = 0x2297; };
  'ClockwiseContourIntegral;' => { output->first = 0x2232; };
  'CloseCurlyDoubleQuote;' => { output->first = 0x201d; };
  'CloseCurlyQuote;' => { output->first = 0x2019; };
  'Colon;' => { output->first = 0x2237; };
  'Colone;' => { output->first = 0x2a74; };
  'Congruent;' => { output->first = 0x2261; };
  'Conint;' => { output->first = 0x222f; };
  'ContourIntegral;' => { output->first = 0x222e; };
  'Copf;' => { output->first = 0x2102; };
  'Coproduct;' => { output->first = 0x2210; };
  'CounterClockwiseContourIntegral;' => { output->first = 0x2233; };
  'Cross;' => { output->first = 0x2a2f; };
  'Cscr;' => { output->first = 0x0001d49e; };
  'Cup;' => { output->first = 0x22d3; };
  'CupCap;' => { output->first = 0x224d; };
  'DD;' => { output->first = 0x2145; };
  'DDotrahd;' => { output->first = 0x2911; };
  'DJcy;' => { output->first = 0x0402; };
  'DScy;' => { output->first = 0x0405; };
  'DZcy;' => { output->first = 0x040f; };
  'Dagger;' => { output->first = 0x2021; };
  'Darr;' => { output->first = 0x21a1; };
  'Dashv;' => { output->first = 0x2ae4; };
  'Dcaron;' => { output->first = 0x010e; };
  'Dcy;' => { output->first = 0x0414; };
  'Del;' => { output->first = 0x2207; };
  'Delta;' => { output->first = 0x0394; };
  'Dfr;' => { output->first = 0x0001d507; };
  'DiacriticalAcute;' => { output->first = 0xb4; };
  'DiacriticalDot;' => { output->first = 0x02d9; };
  'DiacriticalDoubleAcute;' => { output->first = 0x02dd; };
  'DiacriticalGrave;' => { output->first = 0x60; };
  'DiacriticalTilde;' => { output->first = 0x02dc; };
  'Diamond;' => { output->first = 0x22c4; };
  'DifferentialD;' => { output->first = 0x2146; };
  'Dopf;' => { output->first = 0x0001d53b; };
  'Dot;' => { output->first = 0xa8; };
  'DotDot;' => { output->first = 0x20dc; };
  'DotEqual;' => { output->first = 0x2250; };
  'DoubleContourIntegral;' => { output->first = 0x222f; };
  'DoubleDot;' => { output->first = 0xa8; };
  'DoubleDownArrow;' => { output->first = 0x21d3; };
  'DoubleLeftArrow;' => { output->first = 0x21d0; };
  'DoubleLeftRightArrow;' => { output->first = 0x21d4; };
  'DoubleLeftTee;' => { output->first = 0x2ae4; };
  'DoubleLongLeftArrow;' => { output->first = 0x27f8; };
  'DoubleLongLeftRightArrow;' => { output->first = 0x27fa; };
  'DoubleLongRightArrow;' => { output->first = 0x27f9; };
  'DoubleRightArrow;' => { output->first = 0x21d2; };
  'DoubleRightTee;' => { output->first = 0x22a8; };
  'DoubleUpArrow;' => { output->first = 0x21d1; };
  'DoubleUpDownArrow;' => { output->first = 0x21d5; };
  'DoubleVerticalBar;' => { output->first = 0x2225; };
  'DownArrow;' => { output->first = 0x2193; };
  'DownArrowBar;' => { output->first = 0x2913; };
  'DownArrowUpArrow;' => { output->first = 0x21f5; };
  'DownBreve;' => { output->first = 0x0311; };
  'DownLeftRightVector;' => { output->first = 0x2950; };
  'DownLeftTeeVector;' => { output->first = 0x295e; };
  'DownLeftVector;' => { output->first = 0x21bd; };
  'DownLeftVectorBar;' => { output->first = 0x2956; };
  'DownRightTeeVector;' => { output->first = 0x295f; };
  'DownRightVector;' => { output->first = 0x21c1; };
  'DownRightVectorBar;' => { output->first = 0x2957; };
  'DownTee;' => { output->first = 0x22a4; };
  'DownTeeArrow;' => { output->first = 0x21a7; };
  'Downarrow;' => { output->first = 0x21d3; };
  'Dscr;' => { output->first = 0x0001d49f; };
  'Dstrok;' => { output->first = 0x0110; };
  'ENG;' => { output->first = 0x014a; };
  'ETH;' => { output->first = 0xd0; };
  'ETH' => { output->first = 0xd0; };
  'Eacute;' => { output->first = 0xc9; };
  'Eacute' => { output->first = 0xc9; };
  'Ecaron;' => { output->first = 0x011a; };
  'Ecirc;' => { output->first = 0xca; };
  'Ecirc' => { output->first = 0xca; };
  'Ecy;' => { output->first = 0x042d; };
  'Edot;' => { output->first = 0x0116; };
  'Efr;' => { output->first = 0x0001d508; };
  'Egrave;' => { output->first = 0xc8; };
  'Egrave' => { output->first = 0xc8; };
  'Element;' => { output->first = 0x2208; };
  'Emacr;' => { output->first = 0x0112; };
  'EmptySmallSquare;' => { output->first = 0x25fb; };
  'EmptyVerySmallSquare;' => { output->first = 0x25ab; };
  'Eogon;' => { output->first = 0x0118; };
  'Eopf;' => { output->first = 0x0001d53c; };
  'Epsilon;' => { output->first = 0x0395; };
  'Equal;' => { output->first = 0x2a75; };
  'EqualTilde;' => { output->first = 0x2242; };
  'Equilibrium;' => { output->first = 0x21cc; };
  'Escr;' => { output->first = 0x2130; };
  'Esim;' => { output->first = 0x2a73; };
  'Eta;' => { output->first = 0x0397; };
  'Euml;' => { output->first = 0xcb; };
  'Euml' => { output->first = 0xcb; };
  'Exists;' => { output->first = 0x2203; };
  'ExponentialE;' => { output->first = 0x2147; };
  'Fcy;' => { output->first = 0x0424; };
  'Ffr;' => { output->first = 0x0001d509; };
  'FilledSmallSquare;' => { output->first = 0x25fc; };
  'FilledVerySmallSquare;' => { output->first = 0x25aa; };
  'Fopf;' => { output->first = 0x0001d53d; };
  'ForAll;' => { output->first = 0x2200; };
  'Fouriertrf;' => { output->first = 0x2131; };
  'Fscr;' => { output->first = 0x2131; };
  'GJcy;' => { output->first = 0x0403; };
  'GT;' => { output->first = 0x3e; };
  'GT' => { output->first = 0x3e; };
  'Gamma;' => { output->first = 0x0393; };
  'Gammad;' => { output->first = 0x03dc; };
  'Gbreve;' => { output->first = 0x011e; };
  'Gcedil;' => { output->first = 0x0122; };
  'Gcirc;' => { output->first = 0x011c; };
  'Gcy;' => { output->first = 0x0413; };
  'Gdot;' => { output->first = 0x0120; };
  'Gfr;' => { output->first = 0x0001d50a; };
  'Gg;' => { output->first = 0x22d9; };
  'Gopf;' => { output->first = 0x0001d53e; };
  'GreaterEqual;' => { output->first = 0x2265; };
  'GreaterEqualLess;' => { output->first = 0x22db; };
  'GreaterFullEqual;' => { output->first = 0x2267; };
  'GreaterGreater;' => { output->first = 0x2aa2; };
  'GreaterLess;' => { output->first = 0x2277; };
  'GreaterSlantEqual;' => { output->first = 0x2a7e; };
  'GreaterTilde;' => { output->first = 0x2273; };
  'Gscr;' => { output->first = 0x0001d4a2; };
  'Gt;' => { output->first = 0x226b; };
  'HARDcy;' => { output->first = 0x042a; };
  'Hacek;' => { output->first = 0x02c7; };
  'Hat;' => { output->first = 0x5e; };
  'Hcirc;' => { output->first = 0x0124; };
  'Hfr;' => { output->first = 0x210c; };
  'HilbertSpace;' => { output->first = 0x210b; };
  'Hopf;' => { output->first = 0x210d; };
  'HorizontalLine;' => { output->first = 0x2500; };
  'Hscr;' => { output->first = 0x210b; };
  'Hstrok;' => { output->first = 0x0126; };
  'HumpDownHump;' => { output->first = 0x224e; };
  'HumpEqual;' => { output->first = 0x224f; };
  'IEcy;' => { output->first = 0x0415; };
  'IJlig;' => { output->first = 0x0132; };
  'IOcy;' => { output->first = 0x0401; };
  'Iacute;' => { output->first = 0xcd; };
  'Iacute' => { output->first = 0xcd; };
  'Icirc;' => { output->first = 0xce; };
  'Icirc' => { output->first = 0xce; };
  'Icy;' => { output->first = 0x0418; };
  'Idot;' => { output->first = 0x0130; };
  'Ifr;' => { output->first = 0x2111; };
  'Igrave;' => { output->first = 0xcc; };
  'Igrave' => { output->first = 0xcc; };
  'Im;' => { output->first = 0x2111; };
  'Imacr;' => { output->first = 0x012a; };
  'ImaginaryI;' => { output->first = 0x2148; };
  'Implies;' => { output->first = 0x21d2; };
  'Int;' => { output->first = 0x222c; };
  'Integral;' => { output->first = 0x222b; };
  'Intersection;' => { output->first = 0x22c2; };
  'InvisibleComma;' => { output->first = 0x2063; };
  'InvisibleTimes;' => { output->first = 0x2062; };
  'Iogon;' => { output->first = 0x012e; };
  'Iopf;' => { output->first = 0x0001d540; };
  'Iota;' => { output->first = 0x0399; };
  'Iscr;' => { output->first = 0x2110; };
  'Itilde;' => { output->first = 0x0128; };
  'Iukcy;' => { output->first = 0x0406; };
  'Iuml;' => { output->first = 0xcf; };
  'Iuml' => { output->first = 0xcf; };
  'Jcirc;' => { output->first = 0x0134; };
  'Jcy;' => { output->first = 0x0419; };
  'Jfr;' => { output->first = 0x0001d50d; };
  'Jopf;' => { output->first = 0x0001d541; };
  'Jscr;' => { output->first = 0x0001d4a5; };
  'Jsercy;' => { output->first = 0x0408; };
  'Jukcy;' => { output->first = 0x0404; };
  'KHcy;' => { output->first = 0x0425; };
  'KJcy;' => { output->first = 0x040c; };
  'Kappa;' => { output->first = 0x039a; };
  'Kcedil;' => { output->first = 0x0136; };
  'Kcy;' => { output->first = 0x041a; };
  'Kfr;' => { output->first = 0x0001d50e; };
  'Kopf;' => { output->first = 0x0001d542; };
  'Kscr;' => { output->first = 0x0001d4a6; };
  'LJcy;' => { output->first = 0x0409; };
  'LT;' => { output->first = 0x3c; };
  'LT' => { output->first = 0x3c; };
  'Lacute;' => { output->first = 0x0139; };
  'Lambda;' => { output->first = 0x039b; };
  'Lang;' => { output->first = 0x27ea; };
  'Laplacetrf;' => { output->first = 0x2112; };
  'Larr;' => { output->first = 0x219e; };
  'Lcaron;' => { output->first = 0x013d; };
  'Lcedil;' => { output->first = 0x013b; };
  'Lcy;' => { output->first = 0x041b; };
  'LeftAngleBracket;' => { output->first = 0x27e8; };
  'LeftArrow;' => { output->first = 0x2190; };
  'LeftArrowBar;' => { output->first = 0x21e4; };
  'LeftArrowRightArrow;' => { output->first = 0x21c6; };
  'LeftCeiling;' => { output->first = 0x2308; };
  'LeftDoubleBracket;' => { output->first = 0x27e6; };
  'LeftDownTeeVector;' => { output->first = 0x2961; };
  'LeftDownVector;' => { output->first = 0x21c3; };
  'LeftDownVectorBar;' => { output->first = 0x2959; };
  'LeftFloor;' => { output->first = 0x230a; };
  'LeftRightArrow;' => { output->first = 0x2194; };
  'LeftRightVector;' => { output->first = 0x294e; };
  'LeftTee;' => { output->first = 0x22a3; };
  'LeftTeeArrow;' => { output->first = 0x21a4; };
  'LeftTeeVector;' => { output->first = 0x295a; };
  'LeftTriangle;' => { output->first = 0x22b2; };
  'LeftTriangleBar;' => { output->first = 0x29cf; };
  'LeftTriangleEqual;' => { output->first = 0x22b4; };
  'LeftUpDownVector;' => { output->first = 0x2951; };
  'LeftUpTeeVector;' => { output->first = 0x2960; };
  'LeftUpVector;' => { output->first = 0x21bf; };
  'LeftUpVectorBar;' => { output->first = 0x2958; };
  'LeftVector;' => { output->first = 0x21bc; };
  'LeftVectorBar;' => { output->first = 0x2952; };
  'Leftarrow;' => { output->first = 0x21d0; };
  'Leftrightarrow;' => { output->first = 0x21d4; };
  'LessEqualGreater;' => { output->first = 0x22da; };
  'LessFullEqual;' => { output->first = 0x2266; };
  'LessGreater;' => { output->first = 0x2276; };
  'LessLess;' => { output->first = 0x2aa1; };
  'LessSlantEqual;' => { output->first = 0x2a7d; };
  'LessTilde;' => { output->first = 0x2272; };
  'Lfr;' => { output->first = 0x0001d50f; };
  'Ll;' => { output->first = 0x22d8; };
  'Lleftarrow;' => { output->first = 0x21da; };
  'Lmidot;' => { output->first = 0x013f; };
  'LongLeftArrow;' => { output->first = 0x27f5; };
  'LongLeftRightArrow;' => { output->first = 0x27f7; };
  'LongRightArrow;' => { output->first = 0x27f6; };
  'Longleftarrow;' => { output->first = 0x27f8; };
  'Longleftrightarrow;' => { output->first = 0x27fa; };
  'Longrightarrow;' => { output->first = 0x27f9; };
  'Lopf;' => { output->first = 0x0001d543; };
  'LowerLeftArrow;' => { output->first = 0x2199; };
  'LowerRightArrow;' => { output->first = 0x2198; };
  'Lscr;' => { output->first = 0x2112; };
  'Lsh;' => { output->first = 0x21b0; };
  'Lstrok;' => { output->first = 0x0141; };
  'Lt;' => { output->first = 0x226a; };
  'Map;' => { output->first = 0x2905; };
  'Mcy;' => { output->first = 0x041c; };
  'MediumSpace;' => { output->first = 0x205f; };
  'Mellintrf;' => { output->first = 0x2133; };
  'Mfr;' => { output->first = 0x0001d510; };
  'MinusPlus;' => { output->first = 0x2213; };
  'Mopf;' => { output->first = 0x0001d544; };
  'Mscr;' => { output->first = 0x2133; };
  'Mu;' => { output->first = 0x039c; };
  'NJcy;' => { output->first = 0x040a; };
  'Nacute;' => { output->first = 0x0143; };
  'Ncaron;' => { output->first = 0x0147; };
  'Ncedil;' => { output->first = 0x0145; };
  'Ncy;' => { output->first = 0x041d; };
  'NegativeMediumSpace;' => { output->first = 0x200b; };
  'NegativeThickSpace;' => { output->first = 0x200b; };
  'NegativeThinSpace;' => { output->first = 0x200b; };
  'NegativeVeryThinSpace;' => { output->first = 0x200b; };
  'NestedGreaterGreater;' => { output->first = 0x226b; };
  'NestedLessLess;' => { output->first = 0x226a; };
  'NewLine;' => { output->first = 0x0a; };
  'Nfr;' => { output->first = 0x0001d511; };
  'NoBreak;' => { output->first = 0x2060; };
  'NonBreakingSpace;' => { output->first = 0xa0; };
  'Nopf;' => { output->first = 0x2115; };
  'Not;' => { output->first = 0x2aec; };
  'NotCongruent;' => { output->first = 0x2262; };
  'NotCupCap;' => { output->first = 0x226d; };
  'NotDoubleVerticalBar;' => { output->first = 0x2226; };
  'NotElement;' => { output->first = 0x2209; };
  'NotEqual;' => { output->first = 0x2260; };
  'NotEqualTilde;' => { output->first = 0x2242; output->second = 0x0338; };
  'NotExists;' => { output->first = 0x2204; };
  'NotGreater;' => { output->first = 0x226f; };
  'NotGreaterEqual;' => { output->first = 0x2271; };
  'NotGreaterFullEqual;' => { output->first = 0x2267; output->second = 0x0338; };
  'NotGreaterGreater;' => { output->first = 0x226b; output->second = 0x0338; };
  'NotGreaterLess;' => { output->first = 0x2279; };
  'NotGreaterSlantEqual;' => { output->first = 0x2a7e; output->second = 0x0338; };
  'NotGreaterTilde;' => { output->first = 0x2275; };
  'NotHumpDownHump;' => { output->first = 0x224e; output->second = 0x0338; };
  'NotHumpEqual;' => { output->first = 0x224f; output->second = 0x0338; };
  'NotLeftTriangle;' => { output->first = 0x22ea; };
  'NotLeftTriangleBar;' => { output->first = 0x29cf; output->second = 0x0338; };
  'NotLeftTriangleEqual;' => { output->first = 0x22ec; };
  'NotLess;' => { output->first = 0x226e; };
  'NotLessEqual;' => { output->first = 0x2270; };
  'NotLessGreater;' => { output->first = 0x2278; };
  'NotLessLess;' => { output->first = 0x226a; output->second = 0x0338; };
  'NotLessSlantEqual;' => { output->first = 0x2a7d; output->second = 0x0338; };
  'NotLessTilde;' => { output->first = 0x2274; };
  'NotNestedGreaterGreater;' => { output->first = 0x2aa2; output->second = 0x0338; };
  'NotNestedLessLess;' => { output->first = 0x2aa1; output->second = 0x0338; };
  'NotPrecedes;' => { output->first = 0x2280; };
  'NotPrecedesEqual;' => { output->first = 0x2aaf; output->second = 0x0338; };
  'NotPrecedesSlantEqual;' => { output->first = 0x22e0; };
  'NotReverseElement;' => { output->first = 0x220c; };
  'NotRightTriangle;' => { output->first = 0x22eb; };
  'NotRightTriangleBar;' => { output->first = 0x29d0; output->second = 0x0338; };
  'NotRightTriangleEqual;' => { output->first = 0x22ed; };
  'NotSquareSubset;' => { output->first = 0x228f; output->second = 0x0338; };
  'NotSquareSubsetEqual;' => { output->first = 0x22e2; };
  'NotSquareSuperset;' => { output->first = 0x2290; output->second = 0x0338; };
  'NotSquareSupersetEqual;' => { output->first = 0x22e3; };
  'NotSubset;' => { output->first = 0x2282; output->second = 0x20d2; };
  'NotSubsetEqual;' => { output->first = 0x2288; };
  'NotSucceeds;' => { output->first = 0x2281; };
  'NotSucceedsEqual;' => { output->first = 0x2ab0; output->second = 0x0338; };
  'NotSucceedsSlantEqual;' => { output->first = 0x22e1; };
  'NotSucceedsTilde;' => { output->first = 0x227f; output->second = 0x0338; };
  'NotSuperset;' => { output->first = 0x2283; output->second = 0x20d2; };
  'NotSupersetEqual;' => { output->first = 0x2289; };
  'NotTilde;' => { output->first = 0x2241; };
  'NotTildeEqual;' => { output->first = 0x2244; };
  'NotTildeFullEqual;' => { output->first = 0x2247; };
  'NotTildeTilde;' => { output->first = 0x2249; };
  'NotVerticalBar;' => { output->first = 0x2224; };
  'Nscr;' => { output->first = 0x0001d4a9; };
  'Ntilde;' => { output->first = 0xd1; };
  'Ntilde' => { output->first = 0xd1; };
  'Nu;' => { output->first = 0x039d; };
  'OElig;' => { output->first = 0x0152; };
  'Oacute;' => { output->first = 0xd3; };
  'Oacute' => { output->first = 0xd3; };
  'Ocirc;' => { output->first = 0xd4; };
  'Ocirc' => { output->first = 0xd4; };
  'Ocy;' => { output->first = 0x041e; };
  'Odblac;' => { output->first = 0x0150; };
  'Ofr;' => { output->first = 0x0001d512; };
  'Ograve;' => { output->first = 0xd2; };
  'Ograve' => { output->first = 0xd2; };
  'Omacr;' => { output->first = 0x014c; };
  'Omega;' => { output->first = 0x03a9; };
  'Omicron;' => { output->first = 0x039f; };
  'Oopf;' => { output->first = 0x0001d546; };
  'OpenCurlyDoubleQuote;' => { output->first = 0x201c; };
  'OpenCurlyQuote;' => { output->first = 0x2018; };
  'Or;' => { output->first = 0x2a54; };
  'Oscr;' => { output->first = 0x0001d4aa; };
  'Oslash;' => { output->first = 0xd8; };
  'Oslash' => { output->first = 0xd8; };
  'Otilde;' => { output->first = 0xd5; };
  'Otilde' => { output->first = 0xd5; };
  'Otimes;' => { output->first = 0x2a37; };
  'Ouml;' => { output->first = 0xd6; };
  'Ouml' => { output->first = 0xd6; };
  'OverBar;' => { output->first = 0x203e; };
  'OverBrace;' => { output->first = 0x23de; };
  'OverBracket;' => { output->first = 0x23b4; };
  'OverParenthesis;' => { output->first = 0x23dc; };
  'PartialD;' => { output->first = 0x2202; };
  'Pcy;' => { output->first = 0x041f; };
  'Pfr;' => { output->first = 0x0001d513; };
  'Phi;' => { output->first = 0x03a6; };
  'Pi;' => { output->first = 0x03a0; };
  'PlusMinus;' => { output->first = 0xb1; };
  'Poincareplane;' => { output->first = 0x210c; };
  'Popf;' => { output->first = 0x2119; };
  'Pr;' => { output->first = 0x2abb; };
  'Precedes;' => { output->first = 0x227a; };
  'PrecedesEqual;' => { output->first = 0x2aaf; };
  'PrecedesSlantEqual;' => { output->first = 0x227c; };
  'PrecedesTilde;' => { output->first = 0x227e; };
  'Prime;' => { output->first = 0x2033; };
  'Product;' => { output->first = 0x220f; };
  'Proportion;' => { output->first = 0x2237; };
  'Proportional;' => { output->first = 0x221d; };
  'Pscr;' => { output->first = 0x0001d4ab; };
  'Psi;' => { output->first = 0x03a8; };
  'QUOT;' => { output->first = 0x22; };
  'QUOT' => { output->first = 0x22; };
  'Qfr;' => { output->first = 0x0001d514; };
  'Qopf;' => { output->first = 0x211a; };
  'Qscr;' => { output->first = 0x0001d4ac; };
  'RBarr;' => { output->first = 0x2910; };
  'REG;' => { output->first = 0xae; };
  'REG' => { output->first = 0xae; };
  'Racute;' => { output->first = 0x0154; };
  'Rang;' => { output->first = 0x27eb; };
  'Rarr;' => { output->first = 0x21a0; };
  'Rarrtl;' => { output->first = 0x2916; };
  'Rcaron;' => { output->first = 0x0158; };
  'Rcedil;' => { output->first = 0x0156; };
  'Rcy;' => { output->first = 0x0420; };
  'Re;' => { output->first = 0x211c; };
  'ReverseElement;' => { output->first = 0x220b; };
  'ReverseEquilibrium;' => { output->first = 0x21cb; };
  'ReverseUpEquilibrium;' => { output->first = 0x296f; };
  'Rfr;' => { output->first = 0x211c; };
  'Rho;' => { output->first = 0x03a1; };
  'RightAngleBracket;' => { output->first = 0x27e9; };
  'RightArrow;' => { output->first = 0x2192; };
  'RightArrowBar;' => { output->first = 0x21e5; };
  'RightArrowLeftArrow;' => { output->first = 0x21c4; };
  'RightCeiling;' => { output->first = 0x2309; };
  'RightDoubleBracket;' => { output->first = 0x27e7; };
  'RightDownTeeVector;' => { output->first = 0x295d; };
  'RightDownVector;' => { output->first = 0x21c2; };
  'RightDownVectorBar;' => { output->first = 0x2955; };
  'RightFloor;' => { output->first = 0x230b; };
  'RightTee;' => { output->first = 0x22a2; };
  'RightTeeArrow;' => { output->first = 0x21a6; };
  'RightTeeVector;' => { output->first = 0x295b; };
  'RightTriangle;' => { output->first = 0x22b3; };
  'RightTriangleBar;' => { output->first = 0x29d0; };
  'RightTriangleEqual;' => { output->first = 0x22b5; };
  'RightUpDownVector;' => { output->first = 0x294f; };
  'RightUpTeeVector;' => { output->first = 0x295c; };
  'RightUpVector;' => { output->first = 0x21be; };
  'RightUpVectorBar;' => { output->first = 0x2954; };
  'RightVector;' => { output->first = 0x21c0; };
  'RightVectorBar;' => { output->first = 0x2953; };
  'Rightarrow;' => { output->first = 0x21d2; };
  'Ropf;' => { output->first = 0x211d; };
  'RoundImplies;' => { output->first = 0x2970; };
  'Rrightarrow;' => { output->first = 0x21db; };
  'Rscr;' => { output->first = 0x211b; };
  'Rsh;' => { output->first = 0x21b1; };
  'RuleDelayed;' => { output->first = 0x29f4; };
  'SHCHcy;' => { output->first = 0x0429; };
  'SHcy;' => { output->first = 0x0428; };
  'SOFTcy;' => { output->first = 0x042c; };
  'Sacute;' => { output->first = 0x015a; };
  'Sc;' => { output->first = 0x2abc; };
  'Scaron;' => { output->first = 0x0160; };
  'Scedil;' => { output->first = 0x015e; };
  'Scirc;' => { output->first = 0x015c; };
  'Scy;' => { output->first = 0x0421; };
  'Sfr;' => { output->first = 0x0001d516; };
  'ShortDownArrow;' => { output->first = 0x2193; };
  'ShortLeftArrow;' => { output->first = 0x2190; };
  'ShortRightArrow;' => { output->first = 0x2192; };
  'ShortUpArrow;' => { output->first = 0x2191; };
  'Sigma;' => { output->first = 0x03a3; };
  'SmallCircle;' => { output->first = 0x2218; };
  'Sopf;' => { output->first = 0x0001d54a; };
  'Sqrt;' => { output->first = 0x221a; };
  'Square;' => { output->first = 0x25a1; };
  'SquareIntersection;' => { output->first = 0x2293; };
  'SquareSubset;' => { output->first = 0x228f; };
  'SquareSubsetEqual;' => { output->first = 0x2291; };
  'SquareSuperset;' => { output->first = 0x2290; };
  'SquareSupersetEqual;' => { output->first = 0x2292; };
  'SquareUnion;' => { output->first = 0x2294; };
  'Sscr;' => { output->first = 0x0001d4ae; };
  'Star;' => { output->first = 0x22c6; };
  'Sub;' => { output->first = 0x22d0; };
  'Subset;' => { output->first = 0x22d0; };
  'SubsetEqual;' => { output->first = 0x2286; };
  'Succeeds;' => { output->first = 0x227b; };
  'SucceedsEqual;' => { output->first = 0x2ab0; };
  'SucceedsSlantEqual;' => { output->first = 0x227d; };
  'SucceedsTilde;' => { output->first = 0x227f; };
  'SuchThat;' => { output->first = 0x220b; };
  'Sum;' => { output->first = 0x2211; };
  'Sup;' => { output->first = 0x22d1; };
  'Superset;' => { output->first = 0x2283; };
  'SupersetEqual;' => { output->first = 0x2287; };
  'Supset;' => { output->first = 0x22d1; };
  'THORN;' => { output->first = 0xde; };
  'THORN' => { output->first = 0xde; };
  'TRADE;' => { output->first = 0x2122; };
  'TSHcy;' => { output->first = 0x040b; };
  'TScy;' => { output->first = 0x0426; };
  'Tab;' => { output->first = 0x09; };
  'Tau;' => { output->first = 0x03a4; };
  'Tcaron;' => { output->first = 0x0164; };
  'Tcedil;' => { output->first = 0x0162; };
  'Tcy;' => { output->first = 0x0422; };
  'Tfr;' => { output->first = 0x0001d517; };
  'Therefore;' => { output->first = 0x2234; };
  'Theta;' => { output->first = 0x0398; };
  'ThickSpace;' => { output->first = 0x205f; output->second = 0x200a; };
  'ThinSpace;' => { output->first = 0x2009; };
  'Tilde;' => { output->first = 0x223c; };
  'TildeEqual;' => { output->first = 0x2243; };
  'TildeFullEqual;' => { output->first = 0x2245; };
  'TildeTilde;' => { output->first = 0x2248; };
  'Topf;' => { output->first = 0x0001d54b; };
  'TripleDot;' => { output->first = 0x20db; };
  'Tscr;' => { output->first = 0x0001d4af; };
  'Tstrok;' => { output->first = 0x0166; };
  'Uacute;' => { output->first = 0xda; };
  'Uacute' => { output->first = 0xda; };
  'Uarr;' => { output->first = 0x219f; };
  'Uarrocir;' => { output->first = 0x2949; };
  'Ubrcy;' => { output->first = 0x040e; };
  'Ubreve;' => { output->first = 0x016c; };
  'Ucirc;' => { output->first = 0xdb; };
  'Ucirc' => { output->first = 0xdb; };
  'Ucy;' => { output->first = 0x0423; };
  'Udblac;' => { output->first = 0x0170; };
  'Ufr;' => { output->first = 0x0001d518; };
  'Ugrave;' => { output->first = 0xd9; };
  'Ugrave' => { output->first = 0xd9; };
  'Umacr;' => { output->first = 0x016a; };
  'UnderBar;' => { output->first = 0x5f; };
  'UnderBrace;' => { output->first = 0x23df; };
  'UnderBracket;' => { output->first = 0x23b5; };
  'UnderParenthesis;' => { output->first = 0x23dd; };
  'Union;' => { output->first = 0x22c3; };
  'UnionPlus;' => { output->first = 0x228e; };
  'Uogon;' => { output->first = 0x0172; };
  'Uopf;' => { output->first = 0x0001d54c; };
  'UpArrow;' => { output->first = 0x2191; };
  'UpArrowBar;' => { output->first = 0x2912; };
  'UpArrowDownArrow;' => { output->first = 0x21c5; };
  'UpDownArrow;' => { output->first = 0x2195; };
  'UpEquilibrium;' => { output->first = 0x296e; };
  'UpTee;' => { output->first = 0x22a5; };
  'UpTeeArrow;' => { output->first = 0x21a5; };
  'Uparrow;' => { output->first = 0x21d1; };
  'Updownarrow;' => { output->first = 0x21d5; };
  'UpperLeftArrow;' => { output->first = 0x2196; };
  'UpperRightArrow;' => { output->first = 0x2197; };
  'Upsi;' => { output->first = 0x03d2; };
  'Upsilon;' => { output->first = 0x03a5; };
  'Uring;' => { output->first = 0x016e; };
  'Uscr;' => { output->first = 0x0001d4b0; };
  'Utilde;' => { output->first = 0x0168; };
  'Uuml;' => { output->first = 0xdc; };
  'Uuml' => { output->first = 0xdc; };
  'VDash;' => { output->first = 0x22ab; };
  'Vbar;' => { output->first = 0x2aeb; };
  'Vcy;' => { output->first = 0x0412; };
  'Vdash;' => { output->first = 0x22a9; };
  'Vdashl;' => { output->first = 0x2ae6; };
  'Vee;' => { output->first = 0x22c1; };
  'Verbar;' => { output->first = 0x2016; };
  'Vert;' => { output->first = 0x2016; };
  'VerticalBar;' => { output->first = 0x2223; };
  'VerticalLine;' => { output->first = 0x7c; };
  'VerticalSeparator;' => { output->first = 0x2758; };
  'VerticalTilde;' => { output->first = 0x2240; };
  'VeryThinSpace;' => { output->first = 0x200a; };
  'Vfr;' => { output->first = 0x0001d519; };
  'Vopf;' => { output->first = 0x0001d54d; };
  'Vscr;' => { output->first = 0x0001d4b1; };
  'Vvdash;' => { output->first = 0x22aa; };
  'Wcirc;' => { output->first = 0x0174; };
  'Wedge;' => { output->first = 0x22c0; };
  'Wfr;' => { output->first = 0x0001d51a; };
  'Wopf;' => { output->first = 0x0001d54e; };
  'Wscr;' => { output->first = 0x0001d4b2; };
  'Xfr;' => { output->first = 0x0001d51b; };
  'Xi;' => { output->first = 0x039e; };
  'Xopf;' => { output->first = 0x0001d54f; };
  'Xscr;' => { output->first = 0x0001d4b3; };
  'YAcy;' => { output->first = 0x042f; };
  'YIcy;' => { output->first = 0x0407; };
  'YUcy;' => { output->first = 0x042e; };
  'Yacute;' => { output->first = 0xdd; };
  'Yacute' => { output->first = 0xdd; };
  'Ycirc;' => { output->first = 0x0176; };
  'Ycy;' => { output->first = 0x042b; };
  'Yfr;' => { output->first = 0x0001d51c; };
  'Yopf;' => { output->first = 0x0001d550; };
  'Yscr;' => { output->first = 0x0001d4b4; };
  'Yuml;' => { output->first = 0x0178; };
  'ZHcy;' => { output->first = 0x0416; };
  'Zacute;' => { output->first = 0x0179; };
  'Zcaron;' => { output->first = 0x017d; };
  'Zcy;' => { output->first = 0x0417; };
  'Zdot;' => { output->first = 0x017b; };
  'ZeroWidthSpace;' => { output->first = 0x200b; };
  'Zeta;' => { output->first = 0x0396; };
  'Zfr;' => { output->first = 0x2128; };
  'Zopf;' => { output->first = 0x2124; };
  'Zscr;' => { output->first = 0x0001d4b5; };
  'aacute;' => { output->first = 0xe1; };
  'aacute' => { output->first = 0xe1; };
  'abreve;' => { output->first = 0x0103; };
  'ac;' => { output->first = 0x223e; };
  'acE;' => { output->first = 0x223e; output->second = 0x0333; };
  'acd;' => { output->first = 0x223f; };
  'acirc;' => { output->first = 0xe2; };
  'acirc' => { output->first = 0xe2; };
  'acute;' => { output->first = 0xb4; };
  'acute' => { output->first = 0xb4; };
  'acy;' => { output->first = 0x0430; };
  'aelig;' => { output->first = 0xe6; };
  'aelig' => { output->first = 0xe6; };
  'af;' => { output->first = 0x2061; };
  'afr;' => { output->first = 0x0001d51e; };
  'agrave;' => { output->first = 0xe0; };
  'agrave' => { output->first = 0xe0; };
  'alefsym;' => { output->first = 0x2135; };
  'aleph;' => { output->first = 0x2135; };
  'alpha;' => { output->first = 0x03b1; };
  'amacr;' => { output->first = 0x0101; };
  'amalg;' => { output->first = 0x2a3f; };
  'amp;' => { output->first = 0x26; };
  'amp' => { output->first = 0x26; };
  'and;' => { output->first = 0x2227; };
  'andand;' => { output->first = 0x2a55; };
  'andd;' => { output->first = 0x2a5c; };
  'andslope;' => { output->first = 0x2a58; };
  'andv;' => { output->first = 0x2a5a; };
  'ang;' => { output->first = 0x2220; };
  'ange;' => { output->first = 0x29a4; };
  'angle;' => { output->first = 0x2220; };
  'angmsd;' => { output->first = 0x2221; };
  'angmsdaa;' => { output->first = 0x29a8; };
  'angmsdab;' => { output->first = 0x29a9; };
  'angmsdac;' => { output->first = 0x29aa; };
  'angmsdad;' => { output->first = 0x29ab; };
  'angmsdae;' => { output->first = 0x29ac; };
  'angmsdaf;' => { output->first = 0x29ad; };
  'angmsdag;' => { output->first = 0x29ae; };
  'angmsdah;' => { output->first = 0x29af; };
  'angrt;' => { output->first = 0x221f; };
  'angrtvb;' => { output->first = 0x22be; };
  'angrtvbd;' => { output->first = 0x299d; };
  'angsph;' => { output->first = 0x2222; };
  'angst;' => { output->first = 0xc5; };
  'angzarr;' => { output->first = 0x237c; };
  'aogon;' => { output->first = 0x0105; };
  'aopf;' => { output->first = 0x0001d552; };
  'ap;' => { output->first = 0x2248; };
  'apE;' => { output->first = 0x2a70; };
  'apacir;' => { output->first = 0x2a6f; };
  'ape;' => { output->first = 0x224a; };
  'apid;' => { output->first = 0x224b; };
  'apos;' => { output->first = 0x27; };
  'approx;' => { output->first = 0x2248; };
  'approxeq;' => { output->first = 0x224a; };
  'aring;' => { output->first = 0xe5; };
  'aring' => { output->first = 0xe5; };
  'ascr;' => { output->first = 0x0001d4b6; };
  'ast;' => { output->first = 0x2a; };
  'asymp;' => { output->first = 0x2248; };
  'asympeq;' => { output->first = 0x224d; };
  'atilde;' => { output->first = 0xe3; };
  'atilde' => { output->first = 0xe3; };
  'auml;' => { output->first = 0xe4; };
  'auml' => { output->first = 0xe4; };
  'awconint;' => { output->first = 0x2233; };
  'awint;' => { output->first = 0x2a11; };
  'bNot;' => { output->first = 0x2aed; };
  'backcong;' => { output->first = 0x224c; };
  'backepsilon;' => { output->first = 0x03f6; };
  'backprime;' => { output->first = 0x2035; };
  'backsim;' => { output->first = 0x223d; };
  'backsimeq;' => { output->first = 0x22cd; };
  'barvee;' => { output->first = 0x22bd; };
  'barwed;' => { output->first = 0x2305; };
  'barwedge;' => { output->first = 0x2305; };
  'bbrk;' => { output->first = 0x23b5; };
  'bbrktbrk;' => { output->first = 0x23b6; };
  'bcong;' => { output->first = 0x224c; };
  'bcy;' => { output->first = 0x0431; };
  'bdquo;' => { output->first = 0x201e; };
  'becaus;' => { output->first = 0x2235; };
  'because;' => { output->first = 0x2235; };
  'bemptyv;' => { output->first = 0x29b0; };
  'bepsi;' => { output->first = 0x03f6; };
  'bernou;' => { output->first = 0x212c; };
  'beta;' => { output->first = 0x03b2; };
  'beth;' => { output->first = 0x2136; };
  'between;' => { output->first = 0x226c; };
  'bfr;' => { output->first = 0x0001d51f; };
  'bigcap;' => { output->first = 0x22c2; };
  'bigcirc;' => { output->first = 0x25ef; };
  'bigcup;' => { output->first = 0x22c3; };
  'bigodot;' => { output->first = 0x2a00; };
  'bigoplus;' => { output->first = 0x2a01; };
  'bigotimes;' => { output->first = 0x2a02; };
  'bigsqcup;' => { output->first = 0x2a06; };
  'bigstar;' => { output->first = 0x2605; };
  'bigtriangledown;' => { output->first = 0x25bd; };
  'bigtriangleup;' => { output->first = 0x25b3; };
  'biguplus;' => { output->first = 0x2a04; };
  'bigvee;' => { output->first = 0x22c1; };
  'bigwedge;' => { output->first = 0x22c0; };
  'bkarow;' => { output->first = 0x290d; };
  'blacklozenge;' => { output->first = 0x29eb; };
  'blacksquare;' => { output->first = 0x25aa; };
  'blacktriangle;' => { output->first = 0x25b4; };
  'blacktriangledown;' => { output->first = 0x25be; };
  'blacktriangleleft;' => { output->first = 0x25c2; };
  'blacktriangleright;' => { output->first = 0x25b8; };
  'blank;' => { output->first = 0x2423; };
  'blk12;' => { output->first = 0x2592; };
  'blk14;' => { output->first = 0x2591; };
  'blk34;' => { output->first = 0x2593; };
  'block;' => { output->first = 0x2588; };
  'bne;' => { output->first = 0x3d; output->second = 0x20e5; };
  'bnequiv;' => { output->first = 0x2261; output->second = 0x20e5; };
  'bnot;' => { output->first = 0x2310; };
  'bopf;' => { output->first = 0x0001d553; };
  'bot;' => { output->first = 0x22a5; };
  'bottom;' => { output->first = 0x22a5; };
  'bowtie;' => { output->first = 0x22c8; };
  'boxDL;' => { output->first = 0x2557; };
  'boxDR;' => { output->first = 0x2554; };
  'boxDl;' => { output->first = 0x2556; };
  'boxDr;' => { output->first = 0x2553; };
  'boxH;' => { output->first = 0x2550; };
  'boxHD;' => { output->first = 0x2566; };
  'boxHU;' => { output->first = 0x2569; };
  'boxHd;' => { output->first = 0x2564; };
  'boxHu;' => { output->first = 0x2567; };
  'boxUL;' => { output->first = 0x255d; };
  'boxUR;' => { output->first = 0x255a; };
  'boxUl;' => { output->first = 0x255c; };
  'boxUr;' => { output->first = 0x2559; };
  'boxV;' => { output->first = 0x2551; };
  'boxVH;' => { output->first = 0x256c; };
  'boxVL;' => { output->first = 0x2563; };
  'boxVR;' => { output->first = 0x2560; };
  'boxVh;' => { output->first = 0x256b; };
  'boxVl;' => { output->first = 0x2562; };
  'boxVr;' => { output->first = 0x255f; };
  'boxbox;' => { output->first = 0x29c9; };
  'boxdL;' => { output->first = 0x2555; };
  'boxdR;' => { output->first = 0x2552; };
  'boxdl;' => { output->first = 0x2510; };
  'boxdr;' => { output->first = 0x250c; };
  'boxh;' => { output->first = 0x2500; };
  'boxhD;' => { output->first = 0x2565; };
  'boxhU;' => { output->first = 0x2568; };
  'boxhd;' => { output->first = 0x252c; };
  'boxhu;' => { output->first = 0x2534; };
  'boxminus;' => { output->first = 0x229f; };
  'boxplus;' => { output->first = 0x229e; };
  'boxtimes;' => { output->first = 0x22a0; };
  'boxuL;' => { output->first = 0x255b; };
  'boxuR;' => { output->first = 0x2558; };
  'boxul;' => { output->first = 0x2518; };
  'boxur;' => { output->first = 0x2514; };
  'boxv;' => { output->first = 0x2502; };
  'boxvH;' => { output->first = 0x256a; };
  'boxvL;' => { output->first = 0x2561; };
  'boxvR;' => { output->first = 0x255e; };
  'boxvh;' => { output->first = 0x253c; };
  'boxvl;' => { output->first = 0x2524; };
  'boxvr;' => { output->first = 0x251c; };
  'bprime;' => { output->first = 0x2035; };
  'breve;' => { output->first = 0x02d8; };
  'brvbar;' => { output->first = 0xa6; };
  'brvbar' => { output->first = 0xa6; };
  'bscr;' => { output->first = 0x0001d4b7; };
  'bsemi;' => { output->first = 0x204f; };
  'bsim;' => { output->first = 0x223d; };
  'bsime;' => { output->first = 0x22cd; };
  'bsol;' => { output->first = 0x5c; };
  'bsolb;' => { output->first = 0x29c5; };
  'bsolhsub;' => { output->first = 0x27c8; };
  'bull;' => { output->first = 0x2022; };
  'bullet;' => { output->first = 0x2022; };
  'bump;' => { output->first = 0x224e; };
  'bumpE;' => { output->first = 0x2aae; };
  'bumpe;' => { output->first = 0x224f; };
  'bumpeq;' => { output->first = 0x224f; };
  'cacute;' => { output->first = 0x0107; };
  'cap;' => { output->first = 0x2229; };
  'capand;' => { output->first = 0x2a44; };
  'capbrcup;' => { output->first = 0x2a49; };
  'capcap;' => { output->first = 0x2a4b; };
  'capcup;' => { output->first = 0x2a47; };
  'capdot;' => { output->first = 0x2a40; };
  'caps;' => { output->first = 0x2229; output->second = 0xfe00; };
  'caret;' => { output->first = 0x2041; };
  'caron;' => { output->first = 0x02c7; };
  'ccaps;' => { output->first = 0x2a4d; };
  'ccaron;' => { output->first = 0x010d; };
  'ccedil;' => { output->first = 0xe7; };
  'ccedil' => { output->first = 0xe7; };
  'ccirc;' => { output->first = 0x0109; };
  'ccups;' => { output->first = 0x2a4c; };
  'ccupssm;' => { output->first = 0x2a50; };
  'cdot;' => { output->first = 0x010b; };
  'cedil;' => { output->first = 0xb8; };
  'cedil' => { output->first = 0xb8; };
  'cemptyv;' => { output->first = 0x29b2; };
  'cent;' => { output->first = 0xa2; };
  'cent' => { output->first = 0xa2; };
  'centerdot;' => { output->first = 0xb7; };
  'cfr;' => { output->first = 0x0001d520; };
  'chcy;' => { output->first = 0x0447; };
  'check;' => { output->first = 0x2713; };
  'checkmark;' => { output->first = 0x2713; };
  'chi;' => { output->first = 0x03c7; };
  'cir;' => { output->first = 0x25cb; };
  'cirE;' => { output->first = 0x29c3; };
  'circ;' => { output->first = 0x02c6; };
  'circeq;' => { output->first = 0x2257; };
  'circlearrowleft;' => { output->first = 0x21ba; };
  'circlearrowright;' => { output->first = 0x21bb; };
  'circledR;' => { output->first = 0xae; };
  'circledS;' => { output->first = 0x24c8; };
  'circledast;' => { output->first = 0x229b; };
  'circledcirc;' => { output->first = 0x229a; };
  'circleddash;' => { output->first = 0x229d; };
  'cire;' => { output->first = 0x2257; };
  'cirfnint;' => { output->first = 0x2a10; };
  'cirmid;' => { output->first = 0x2aef; };
  'cirscir;' => { output->first = 0x29c2; };
  'clubs;' => { output->first = 0x2663; };
  'clubsuit;' => { output->first = 0x2663; };
  'colon;' => { output->first = 0x3a; };
  'colone;' => { output->first = 0x2254; };
  'coloneq;' => { output->first = 0x2254; };
  'comma;' => { output->first = 0x2c; };
  'commat;' => { output->first = 0x40; };
  'comp;' => { output->first = 0x2201; };
  'compfn;' => { output->first = 0x2218; };
  'complement;' => { output->first = 0x2201; };
  'complexes;' => { output->first = 0x2102; };
  'cong;' => { output->first = 0x2245; };
  'congdot;' => { output->first = 0x2a6d; };
  'conint;' => { output->first = 0x222e; };
  'copf;' => { output->first = 0x0001d554; };
  'coprod;' => { output->first = 0x2210; };
  'copy;' => { output->first = 0xa9; };
  'copy' => { output->first = 0xa9; };
  'copysr;' => { output->first = 0x2117; };
  'crarr;' => { output->first = 0x21b5; };
  'cross;' => { output->first = 0x2717; };
  'cscr;' => { output->first = 0x0001d4b8; };
  'csub;' => { output->first = 0x2acf; };
  'csube;' => { output->first = 0x2ad1; };
  'csup;' => { output->first = 0x2ad0; };
  'csupe;' => { output->first = 0x2ad2; };
  'ctdot;' => { output->first = 0x22ef; };
  'cudarrl;' => { output->first = 0x2938; };
  'cudarrr;' => { output->first = 0x2935; };
  'cuepr;' => { output->first = 0x22de; };
  'cuesc;' => { output->first = 0x22df; };
  'cularr;' => { output->first = 0x21b6; };
  'cularrp;' => { output->first = 0x293d; };
  'cup;' => { output->first = 0x222a; };
  'cupbrcap;' => { output->first = 0x2a48; };
  'cupcap;' => { output->first = 0x2a46; };
  'cupcup;' => { output->first = 0x2a4a; };
  'cupdot;' => { output->first = 0x228d; };
  'cupor;' => { output->first = 0x2a45; };
  'cups;' => { output->first = 0x222a; output->second = 0xfe00; };
  'curarr;' => { output->first = 0x21b7; };
  'curarrm;' => { output->first = 0x293c; };
  'curlyeqprec;' => { output->first = 0x22de; };
  'curlyeqsucc;' => { output->first = 0x22df; };
  'curlyvee;' => { output->first = 0x22ce; };
  'curlywedge;' => { output->first = 0x22cf; };
  'curren;' => { output->first = 0xa4; };
  'curren' => { output->first = 0xa4; };
  'curvearrowleft;' => { output->first = 0x21b6; };
  'curvearrowright;' => { output->first = 0x21b7; };
  'cuvee;' => { output->first = 0x22ce; };
  'cuwed;' => { output->first = 0x22cf; };
  'cwconint;' => { output->first = 0x2232; };
  'cwint;' => { output->first = 0x2231; };
  'cylcty;' => { output->first = 0x232d; };
  'dArr;' => { output->first = 0x21d3; };
  'dHar;' => { output->first = 0x2965; };
  'dagger;' => { output->first = 0x2020; };
  'daleth;' => { output->first = 0x2138; };
  'darr;' => { output->first = 0x2193; };
  'dash;' => { output->first = 0x2010; };
  'dashv;' => { output->first = 0x22a3; };
  'dbkarow;' => { output->first = 0x290f; };
  'dblac;' => { output->first = 0x02dd; };
  'dcaron;' => { output->first = 0x010f; };
  'dcy;' => { output->first = 0x0434; };
  'dd;' => { output->first = 0x2146; };
  'ddagger;' => { output->first = 0x2021; };
  'ddarr;' => { output->first = 0x21ca; };
  'ddotseq;' => { output->first = 0x2a77; };
  'deg;' => { output->first = 0xb0; };
  'deg' => { output->first = 0xb0; };
  'delta;' => { output->first = 0x03b4; };
  'demptyv;' => { output->first = 0x29b1; };
  'dfisht;' => { output->first = 0x297f; };
  'dfr;' => { output->first = 0x0001d521; };
  'dharl;' => { output->first = 0x21c3; };
  'dharr;' => { output->first = 0x21c2; };
  'diam;' => { output->first = 0x22c4; };
  'diamond;' => { output->first = 0x22c4; };
  'diamondsuit;' => { output->first = 0x2666; };
  'diams;' => { output->first = 0x2666; };
  'die;' => { output->first = 0xa8; };
  'digamma;' => { output->first = 0x03dd; };
  'disin;' => { output->first = 0x22f2; };
  'div;' => { output->first = 0xf7; };
  'divide;' => { output->first = 0xf7; };
  'divide' => { output->first = 0xf7; };
  'divideontimes;' => { output->first = 0x22c7; };
  'divonx;' => { output->first = 0x22c7; };
  'djcy;' => { output->first = 0x0452; };
  'dlcorn;' => { output->first = 0x231e; };
  'dlcrop;' => { output->first = 0x230d; };
  'dollar;' => { output->first = 0x24; };
  'dopf;' => { output->first = 0x0001d555; };
  'dot;' => { output->first = 0x02d9; };
  'doteq;' => { output->first = 0x2250; };
  'doteqdot;' => { output->first = 0x2251; };
  'dotminus;' => { output->first = 0x2238; };
  'dotplus;' => { output->first = 0x2214; };
  'dotsquare;' => { output->first = 0x22a1; };
  'doublebarwedge;' => { output->first = 0x2306; };
  'downarrow;' => { output->first = 0x2193; };
  'downdownarrows;' => { output->first = 0x21ca; };
  'downharpoonleft;' => { output->first = 0x21c3; };
  'downharpoonright;' => { output->first = 0x21c2; };
  'drbkarow;' => { output->first = 0x2910; };
  'drcorn;' => { output->first = 0x231f; };
  'drcrop;' => { output->first = 0x230c; };
  'dscr;' => { output->first = 0x0001d4b9; };
  'dscy;' => { output->first = 0x0455; };
  'dsol;' => { output->first = 0x29f6; };
  'dstrok;' => { output->first = 0x0111; };
  'dtdot;' => { output->first = 0x22f1; };
  'dtri;' => { output->first = 0x25bf; };
  'dtrif;' => { output->first = 0x25be; };
  'duarr;' => { output->first = 0x21f5; };
  'duhar;' => { output->first = 0x296f; };
  'dwangle;' => { output->first = 0x29a6; };
  'dzcy;' => { output->first = 0x045f; };
  'dzigrarr;' => { output->first = 0x27ff; };
  'eDDot;' => { output->first = 0x2a77; };
  'eDot;' => { output->first = 0x2251; };
  'eacute;' => { output->first = 0xe9; };
  'eacute' => { output->first = 0xe9; };
  'easter;' => { output->first = 0x2a6e; };
  'ecaron;' => { output->first = 0x011b; };
  'ecir;' => { output->first = 0x2256; };
  'ecirc;' => { output->first = 0xea; };
  'ecirc' => { output->first = 0xea; };
  'ecolon;' => { output->first = 0x2255; };
  'ecy;' => { output->first = 0x044d; };
  'edot;' => { output->first = 0x0117; };
  'ee;' => { output->first = 0x2147; };
  'efDot;' => { output->first = 0x2252; };
  'efr;' => { output->first = 0x0001d522; };
  'eg;' => { output->first = 0x2a9a; };
  'egrave;' => { output->first = 0xe8; };
  'egrave' => { output->first = 0xe8; };
  'egs;' => { output->first = 0x2a96; };
  'egsdot;' => { output->first = 0x2a98; };
  'el;' => { output->first = 0x2a99; };
  'elinters;' => { output->first = 0x23e7; };
  'ell;' => { output->first = 0x2113; };
  'els;' => { output->first = 0x2a95; };
  'elsdot;' => { output->first = 0x2a97; };
  'emacr;' => { output->first = 0x0113; };
  'empty;' => { output->first = 0x2205; };
  'emptyset;' => { output->first = 0x2205; };
  'emptyv;' => { output->first = 0x2205; };
  'emsp13;' => { output->first = 0x2004; };
  'emsp14;' => { output->first = 0x2005; };
  'emsp;' => { output->first = 0x2003; };
  'eng;' => { output->first = 0x014b; };
  'ensp;' => { output->first = 0x2002; };
  'eogon;' => { output->first = 0x0119; };
  'eopf;' => { output->first = 0x0001d556; };
  'epar;' => { output->first = 0x22d5; };
  'eparsl;' => { output->first = 0x29e3; };
  'eplus;' => { output->first = 0x2a71; };
  'epsi;' => { output->first = 0x03b5; };
  'epsilon;' => { output->first = 0x03b5; };
  'epsiv;' => { output->first = 0x03f5; };
  'eqcirc;' => { output->first = 0x2256; };
  'eqcolon;' => { output->first = 0x2255; };
  'eqsim;' => { output->first = 0x2242; };
  'eqslantgtr;' => { output->first = 0x2a96; };
  'eqslantless;' => { output->first = 0x2a95; };
  'equals;' => { output->first = 0x3d; };
  'equest;' => { output->first = 0x225f; };
  'equiv;' => { output->first = 0x2261; };
  'equivDD;' => { output->first = 0x2a78; };
  'eqvparsl;' => { output->first = 0x29e5; };
  'erDot;' => { output->first = 0x2253; };
  'erarr;' => { output->first = 0x2971; };
  'escr;' => { output->first = 0x212f; };
  'esdot;' => { output->first = 0x2250; };
  'esim;' => { output->first = 0x2242; };
  'eta;' => { output->first = 0x03b7; };
  'eth;' => { output->first = 0xf0; };
  'eth' => { output->first = 0xf0; };
  'euml;' => { output->first = 0xeb; };
  'euml' => { output->first = 0xeb; };
  'euro;' => { output->first = 0x20ac; };
  'excl;' => { output->first = 0x21; };
  'exist;' => { output->first = 0x2203; };
  'expectation;' => { output->first = 0x2130; };
  'exponentiale;' => { output->first = 0x2147; };
  'fallingdotseq;' => { output->first = 0x2252; };
  'fcy;' => { output->first = 0x0444; };
  'female;' => { output->first = 0x2640; };
  'ffilig;' => { output->first = 0xfb03; };
  'fflig;' => { output->first = 0xfb00; };
  'ffllig;' => { output->first = 0xfb04; };
  'ffr;' => { output->first = 0x0001d523; };
  'filig;' => { output->first = 0xfb01; };
  'fjlig;' => { output->first = 0x66; output->second = 0x6a; };
  'flat;' => { output->first = 0x266d; };
  'fllig;' => { output->first = 0xfb02; };
  'fltns;' => { output->first = 0x25b1; };
  'fnof;' => { output->first = 0x0192; };
  'fopf;' => { output->first = 0x0001d557; };
  'forall;' => { output->first = 0x2200; };
  'fork;' => { output->first = 0x22d4; };
  'forkv;' => { output->first = 0x2ad9; };
  'fpartint;' => { output->first = 0x2a0d; };
  'frac12;' => { output->first = 0xbd; };
  'frac12' => { output->first = 0xbd; };
  'frac13;' => { output->first = 0x2153; };
  'frac14;' => { output->first = 0xbc; };
  'frac14' => { output->first = 0xbc; };
  'frac15;' => { output->first = 0x2155; };
  'frac16;' => { output->first = 0x2159; };
  'frac18;' => { output->first = 0x215b; };
  'frac23;' => { output->first = 0x2154; };
  'frac25;' => { output->first = 0x2156; };
  'frac34;' => { output->first = 0xbe; };
  'frac34' => { output->first = 0xbe; };
  'frac35;' => { output->first = 0x2157; };
  'frac38;' => { output->first = 0x215c; };
  'frac45;' => { output->first = 0x2158; };
  'frac56;' => { output->first = 0x215a; };
  'frac58;' => { output->first = 0x215d; };
  'frac78;' => { output->first = 0x215e; };
  'frasl;' => { output->first = 0x2044; };
  'frown;' => { output->first = 0x2322; };
  'fscr;' => { output->first = 0x0001d4bb; };
  'gE;' => { output->first = 0x2267; };
  'gEl;' => { output->first = 0x2a8c; };
  'gacute;' => { output->first = 0x01f5; };
  'gamma;' => { output->first = 0x03b3; };
  'gammad;' => { output->first = 0x03dd; };
  'gap;' => { output->first = 0x2a86; };
  'gbreve;' => { output->first = 0x011f; };
  'gcirc;' => { output->first = 0x011d; };
  'gcy;' => { output->first = 0x0433; };
  'gdot;' => { output->first = 0x0121; };
  'ge;' => { output->first = 0x2265; };
  'gel;' => { output->first = 0x22db; };
  'geq;' => { output->first = 0x2265; };
  'geqq;' => { output->first = 0x2267; };
  'geqslant;' => { output->first = 0x2a7e; };
  'ges;' => { output->first = 0x2a7e; };
  'gescc;' => { output->first = 0x2aa9; };
  'gesdot;' => { output->first = 0x2a80; };
  'gesdoto;' => { output->first = 0x2a82; };
  'gesdotol;' => { output->first = 0x2a84; };
  'gesl;' => { output->first = 0x22db; output->second = 0xfe00; };
  'gesles;' => { output->first = 0x2a94; };
  'gfr;' => { output->first = 0x0001d524; };
  'gg;' => { output->first = 0x226b; };
  'ggg;' => { output->first = 0x22d9; };
  'gimel;' => { output->first = 0x2137; };
  'gjcy;' => { output->first = 0x0453; };
  'gl;' => { output->first = 0x2277; };
  'glE;' => { output->first = 0x2a92; };
  'gla;' => { output->first = 0x2aa5; };
  'glj;' => { output->first = 0x2aa4; };
  'gnE;' => { output->first = 0x2269; };
  'gnap;' => { output->first = 0x2a8a; };
  'gnapprox;' => { output->first = 0x2a8a; };
  'gne;' => { output->first = 0x2a88; };
  'gneq;' => { output->first = 0x2a88; };
  'gneqq;' => { output->first = 0x2269; };
  'gnsim;' => { output->first = 0x22e7; };
  'gopf;' => { output->first = 0x0001d558; };
  'grave;' => { output->first = 0x60; };
  'gscr;' => { output->first = 0x210a; };
  'gsim;' => { output->first = 0x2273; };
  'gsime;' => { output->first = 0x2a8e; };
  'gsiml;' => { output->first = 0x2a90; };
  'gt;' => { output->first = 0x3e; };
  'gt' => { output->first = 0x3e; };
  'gtcc;' => { output->first = 0x2aa7; };
  'gtcir;' => { output->first = 0x2a7a; };
  'gtdot;' => { output->first = 0x22d7; };
  'gtlPar;' => { output->first = 0x2995; };
  'gtquest;' => { output->first = 0x2a7c; };
  'gtrapprox;' => { output->first = 0x2a86; };
  'gtrarr;' => { output->first = 0x2978; };
  'gtrdot;' => { output->first = 0x22d7; };
  'gtreqless;' => { output->first = 0x22db; };
  'gtreqqless;' => { output->first = 0x2a8c; };
  'gtrless;' => { output->first = 0x2277; };
  'gtrsim;' => { output->first = 0x2273; };
  'gvertneqq;' => { output->first = 0x2269; output->second = 0xfe00; };
  'gvnE;' => { output->first = 0x2269; output->second = 0xfe00; };
  'hArr;' => { output->first = 0x21d4; };
  'hairsp;' => { output->first = 0x200a; };
  'half;' => { output->first = 0xbd; };
  'hamilt;' => { output->first = 0x210b; };
  'hardcy;' => { output->first = 0x044a; };
  'harr;' => { output->first = 0x2194; };
  'harrcir;' => { output->first = 0x2948; };
  'harrw;' => { output->first = 0x21ad; };
  'hbar;' => { output->first = 0x210f; };
  'hcirc;' => { output->first = 0x0125; };
  'hearts;' => { output->first = 0x2665; };
  'heartsuit;' => { output->first = 0x2665; };
  'hellip;' => { output->first = 0x2026; };
  'hercon;' => { output->first = 0x22b9; };
  'hfr;' => { output->first = 0x0001d525; };
  'hksearow;' => { output->first = 0x2925; };
  'hkswarow;' => { output->first = 0x2926; };
  'hoarr;' => { output->first = 0x21ff; };
  'homtht;' => { output->first = 0x223b; };
  'hookleftarrow;' => { output->first = 0x21a9; };
  'hookrightarrow;' => { output->first = 0x21aa; };
  'hopf;' => { output->first = 0x0001d559; };
  'horbar;' => { output->first = 0x2015; };
  'hscr;' => { output->first = 0x0001d4bd; };
  'hslash;' => { output->first = 0x210f; };
  'hstrok;' => { output->first = 0x0127; };
  'hybull;' => { output->first = 0x2043; };
  'hyphen;' => { output->first = 0x2010; };
  'iacute;' => { output->first = 0xed; };
  'iacute' => { output->first = 0xed; };
  'ic;' => { output->first = 0x2063; };
  'icirc;' => { output->first = 0xee; };
  'icirc' => { output->first = 0xee; };
  'icy;' => { output->first = 0x0438; };
  'iecy;' => { output->first = 0x0435; };
  'iexcl;' => { output->first = 0xa1; };
  'iexcl' => { output->first = 0xa1; };
  'iff;' => { output->first = 0x21d4; };
  'ifr;' => { output->first = 0x0001d526; };
  'igrave;' => { output->first = 0xec; };
  'igrave' => { output->first = 0xec; };
  'ii;' => { output->first = 0x2148; };
  'iiiint;' => { output->first = 0x2a0c; };
  'iiint;' => { output->first = 0x222d; };
  'iinfin;' => { output->first = 0x29dc; };
  'iiota;' => { output->first = 0x2129; };
  'ijlig;' => { output->first = 0x0133; };
  'imacr;' => { output->first = 0x012b; };
  'image;' => { output->first = 0x2111; };
  'imagline;' => { output->first = 0x2110; };
  'imagpart;' => { output->first = 0x2111; };
  'imath;' => { output->first = 0x0131; };
  'imof;' => { output->first = 0x22b7; };
  'imped;' => { output->first = 0x01b5; };
  'in;' => { output->first = 0x2208; };
  'incare;' => { output->first = 0x2105; };
  'infin;' => { output->first = 0x221e; };
  'infintie;' => { output->first = 0x29dd; };
  'inodot;' => { output->first = 0x0131; };
  'int;' => { output->first = 0x222b; };
  'intcal;' => { output->first = 0x22ba; };
  'integers;' => { output->first = 0x2124; };
  'intercal;' => { output->first = 0x22ba; };
  'intlarhk;' => { output->first = 0x2a17; };
  'intprod;' => { output->first = 0x2a3c; };
  'iocy;' => { output->first = 0x0451; };
  'iogon;' => { output->first = 0x012f; };
  'iopf;' => { output->first = 0x0001d55a; };
  'iota;' => { output->first = 0x03b9; };
  'iprod;' => { output->first = 0x2a3c; };
  'iquest;' => { output->first = 0xbf; };
  'iquest' => { output->first = 0xbf; };
  'iscr;' => { output->first = 0x0001d4be; };
  'isin;' => { output->first = 0x2208; };
  'isinE;' => { output->first = 0x22f9; };
  'isindot;' => { output->first = 0x22f5; };
  'isins;' => { output->first = 0x22f4; };
  'isinsv;' => { output->first = 0x22f3; };
  'isinv;' => { output->first = 0x2208; };
  'it;' => { output->first = 0x2062; };
  'itilde;' => { output->first = 0x0129; };
  'iukcy;' => { output->first = 0x0456; };
  'iuml;' => { output->first = 0xef; };
  'iuml' => { output->first = 0xef; };
  'jcirc;' => { output->first = 0x0135; };
  'jcy;' => { output->first = 0x0439; };
  'jfr;' => { output->first = 0x0001d527; };
  'jmath;' => { output->first = 0x0237; };
  'jopf;' => { output->first = 0x0001d55b; };
  'jscr;' => { output->first = 0x0001d4bf; };
  'jsercy;' => { output->first = 0x0458; };
  'jukcy;' => { output->first = 0x0454; };
  'kappa;' => { output->first = 0x03ba; };
  'kappav;' => { output->first = 0x03f0; };
  'kcedil;' => { output->first = 0x0137; };
  'kcy;' => { output->first = 0x043a; };
  'kfr;' => { output->first = 0x0001d528; };
  'kgreen;' => { output->first = 0x0138; };
  'khcy;' => { output->first = 0x0445; };
  'kjcy;' => { output->first = 0x045c; };
  'kopf;' => { output->first = 0x0001d55c; };
  'kscr;' => { output->first = 0x0001d4c0; };
  'lAarr;' => { output->first = 0x21da; };
  'lArr;' => { output->first = 0x21d0; };
  'lAtail;' => { output->first = 0x291b; };
  'lBarr;' => { output->first = 0x290e; };
  'lE;' => { output->first = 0x2266; };
  'lEg;' => { output->first = 0x2a8b; };
  'lHar;' => { output->first = 0x2962; };
  'lacute;' => { output->first = 0x013a; };
  'laemptyv;' => { output->first = 0x29b4; };
  'lagran;' => { output->first = 0x2112; };
  'lambda;' => { output->first = 0x03bb; };
  'lang;' => { output->first = 0x27e8; };
  'langd;' => { output->first = 0x2991; };
  'langle;' => { output->first = 0x27e8; };
  'lap;' => { output->first = 0x2a85; };
  'laquo;' => { output->first = 0xab; };
  'laquo' => { output->first = 0xab; };
  'larr;' => { output->first = 0x2190; };
  'larrb;' => { output->first = 0x21e4; };
  'larrbfs;' => { output->first = 0x291f; };
  'larrfs;' => { output->first = 0x291d; };
  'larrhk;' => { output->first = 0x21a9; };
  'larrlp;' => { output->first = 0x21ab; };
  'larrpl;' => { output->first = 0x2939; };
  'larrsim;' => { output->first = 0x2973; };
  'larrtl;' => { output->first = 0x21a2; };
  'lat;' => { output->first = 0x2aab; };
  'latail;' => { output->first = 0x2919; };
  'late;' => { output->first = 0x2aad; };
  'lates;' => { output->first = 0x2aad; output->second = 0xfe00; };
  'lbarr;' => { output->first = 0x290c; };
  'lbbrk;' => { output->first = 0x2772; };
  'lbrace;' => { output->first = 0x7b; };
  'lbrack;' => { output->first = 0x5b; };
  'lbrke;' => { output->first = 0x298b; };
  'lbrksld;' => { output->first = 0x298f; };
  'lbrkslu;' => { output->first = 0x298d; };
  'lcaron;' => { output->first = 0x013e; };
  'lcedil;' => { output->first = 0x013c; };
  'lceil;' => { output->first = 0x2308; };
  'lcub;' => { output->first = 0x7b; };
  'lcy;' => { output->first = 0x043b; };
  'ldca;' => { output->first = 0x2936; };
  'ldquo;' => { output->first = 0x201c; };
  'ldquor;' => { output->first = 0x201e; };
  'ldrdhar;' => { output->first = 0x2967; };
  'ldrushar;' => { output->first = 0x294b; };
  'ldsh;' => { output->first = 0x21b2; };
  'le;' => { output->first = 0x2264; };
  'leftarrow;' => { output->first = 0x2190; };
  'leftarrowtail;' => { output->first = 0x21a2; };
  'leftharpoondown;' => { output->first = 0x21bd; };
  'leftharpoonup;' => { output->first = 0x21bc; };
  'leftleftarrows;' => { output->first = 0x21c7; };
  'leftrightarrow;' => { output->first = 0x2194; };
  'leftrightarrows;' => { output->first = 0x21c6; };
  'leftrightharpoons;' => { output->first = 0x21cb; };
  'leftrightsquigarrow;' => { output->first = 0x21ad; };
  'leftthreetimes;' => { output->first = 0x22cb; };
  'leg;' => { output->first = 0x22da; };
  'leq;' => { output->first = 0x2264; };
  'leqq;' => { output->first = 0x2266; };
  'leqslant;' => { output->first = 0x2a7d; };
  'les;' => { output->first = 0x2a7d; };
  'lescc;' => { output->first = 0x2aa8; };
  'lesdot;' => { output->first = 0x2a7f; };
  'lesdoto;' => { output->first = 0x2a81; };
  'lesdotor;' => { output->first = 0x2a83; };
  'lesg;' => { output->first = 0x22da; output->second = 0xfe00; };
  'lesges;' => { output->first = 0x2a93; };
  'lessapprox;' => { output->first = 0x2a85; };
  'lessdot;' => { output->first = 0x22d6; };
  'lesseqgtr;' => { output->first = 0x22da; };
  'lesseqqgtr;' => { output->first = 0x2a8b; };
  'lessgtr;' => { output->first = 0x2276; };
  'lesssim;' => { output->first = 0x2272; };
  'lfisht;' => { output->first = 0x297c; };
  'lfloor;' => { output->first = 0x230a; };
  'lfr;' => { output->first = 0x0001d529; };
  'lg;' => { output->first = 0x2276; };
  'lgE;' => { output->first = 0x2a91; };
  'lhard;' => { output->first = 0x21bd; };
  'lharu;' => { output->first = 0x21bc; };
  'lharul;' => { output->first = 0x296a; };
  'lhblk;' => { output->first = 0x2584; };
  'ljcy;' => { output->first = 0x0459; };
  'll;' => { output->first = 0x226a; };
  'llarr;' => { output->first = 0x21c7; };
  'llcorner;' => { output->first = 0x231e; };
  'llhard;' => { output->first = 0x296b; };
  'lltri;' => { output->first = 0x25fa; };
  'lmidot;' => { output->first = 0x0140; };
  'lmoust;' => { output->first = 0x23b0; };
  'lmoustache;' => { output->first = 0x23b0; };
  'lnE;' => { output->first = 0x2268; };
  'lnap;' => { output->first = 0x2a89; };
  'lnapprox;' => { output->first = 0x2a89; };
  'lne;' => { output->first = 0x2a87; };
  'lneq;' => { output->first = 0x2a87; };
  'lneqq;' => { output->first = 0x2268; };
  'lnsim;' => { output->first = 0x22e6; };
  'loang;' => { output->first = 0x27ec; };
  'loarr;' => { output->first = 0x21fd; };
  'lobrk;' => { output->first = 0x27e6; };
  'longleftarrow;' => { output->first = 0x27f5; };
  'longleftrightarrow;' => { output->first = 0x27f7; };
  'longmapsto;' => { output->first = 0x27fc; };
  'longrightarrow;' => { output->first = 0x27f6; };
  'looparrowleft;' => { output->first = 0x21ab; };
  'looparrowright;' => { output->first = 0x21ac; };
  'lopar;' => { output->first = 0x2985; };
  'lopf;' => { output->first = 0x0001d55d; };
  'loplus;' => { output->first = 0x2a2d; };
  'lotimes;' => { output->first = 0x2a34; };
  'lowast;' => { output->first = 0x2217; };
  'lowbar;' => { output->first = 0x5f; };
  'loz;' => { output->first = 0x25ca; };
  'lozenge;' => { output->first = 0x25ca; };
  'lozf;' => { output->first = 0x29eb; };
  'lpar;' => { output->first = 0x28; };
  'lparlt;' => { output->first = 0x2993; };
  'lrarr;' => { output->first = 0x21c6; };
  'lrcorner;' => { output->first = 0x231f; };
  'lrhar;' => { output->first = 0x21cb; };
  'lrhard;' => { output->first = 0x296d; };
  'lrm;' => { output->first = 0x200e; };
  'lrtri;' => { output->first = 0x22bf; };
  'lsaquo;' => { output->first = 0x2039; };
  'lscr;' => { output->first = 0x0001d4c1; };
  'lsh;' => { output->first = 0x21b0; };
  'lsim;' => { output->first = 0x2272; };
  'lsime;' => { output->first = 0x2a8d; };
  'lsimg;' => { output->first = 0x2a8f; };
  'lsqb;' => { output->first = 0x5b; };
  'lsquo;' => { output->first = 0x2018; };
  'lsquor;' => { output->first = 0x201a; };
  'lstrok;' => { output->first = 0x0142; };
  'lt;' => { output->first = 0x3c; };
  'lt' => { output->first = 0x3c; };
  'ltcc;' => { output->first = 0x2aa6; };
  'ltcir;' => { output->first = 0x2a79; };
  'ltdot;' => { output->first = 0x22d6; };
  'lthree;' => { output->first = 0x22cb; };
  'ltimes;' => { output->first = 0x22c9; };
  'ltlarr;' => { output->first = 0x2976; };
  'ltquest;' => { output->first = 0x2a7b; };
  'ltrPar;' => { output->first = 0x2996; };
  'ltri;' => { output->first = 0x25c3; };
  'ltrie;' => { output->first = 0x22b4; };
  'ltrif;' => { output->first = 0x25c2; };
  'lurdshar;' => { output->first = 0x294a; };
  'luruhar;' => { output->first = 0x2966; };
  'lvertneqq;' => { output->first = 0x2268; output->second = 0xfe00; };
  'lvnE;' => { output->first = 0x2268; output->second = 0xfe00; };
  'mDDot;' => { output->first = 0x223a; };
  'macr;' => { output->first = 0xaf; };
  'macr' => { output->first = 0xaf; };
  'male;' => { output->first = 0x2642; };
  'malt;' => { output->first = 0x2720; };
  'maltese;' => { output->first = 0x2720; };
  'map;' => { output->first = 0x21a6; };
  'mapsto;' => { output->first = 0x21a6; };
  'mapstodown;' => { output->first = 0x21a7; };
  'mapstoleft;' => { output->first = 0x21a4; };
  'mapstoup;' => { output->first = 0x21a5; };
  'marker;' => { output->first = 0x25ae; };
  'mcomma;' => { output->first = 0x2a29; };
  'mcy;' => { output->first = 0x043c; };
  'mdash;' => { output->first = 0x2014; };
  'measuredangle;' => { output->first = 0x2221; };
  'mfr;' => { output->first = 0x0001d52a; };
  'mho;' => { output->first = 0x2127; };
  'micro;' => { output->first = 0xb5; };
  'micro' => { output->first = 0xb5; };
  'mid;' => { output->first = 0x2223; };
  'midast;' => { output->first = 0x2a; };
  'midcir;' => { output->first = 0x2af0; };
  'middot;' => { output->first = 0xb7; };
  'middot' => { output->first = 0xb7; };
  'minus;' => { output->first = 0x2212; };
  'minusb;' => { output->first = 0x229f; };
  'minusd;' => { output->first = 0x2238; };
  'minusdu;' => { output->first = 0x2a2a; };
  'mlcp;' => { output->first = 0x2adb; };
  'mldr;' => { output->first = 0x2026; };
  'mnplus;' => { output->first = 0x2213; };
  'models;' => { output->first = 0x22a7; };
  'mopf;' => { output->first = 0x0001d55e; };
  'mp;' => { output->first = 0x2213; };
  'mscr;' => { output->first = 0x0001d4c2; };
  'mstpos;' => { output->first = 0x223e; };
  'mu;' => { output->first = 0x03bc; };
  'multimap;' => { output->first = 0x22b8; };
  'mumap;' => { output->first = 0x22b8; };
  'nGg;' => { output->first = 0x22d9; output->second = 0x0338; };
  'nGt;' => { output->first = 0x226b; output->second = 0x20d2; };
  'nGtv;' => { output->first = 0x226b; output->second = 0x0338; };
  'nLeftarrow;' => { output->first = 0x21cd; };
  'nLeftrightarrow;' => { output->first = 0x21ce; };
  'nLl;' => { output->first = 0x22d8; output->second = 0x0338; };
  'nLt;' => { output->first = 0x226a; output->second = 0x20d2; };
  'nLtv;' => { output->first = 0x226a; output->second = 0x0338; };
  'nRightarrow;' => { output->first = 0x21cf; };
  'nVDash;' => { output->first = 0x22af; };
  'nVdash;' => { output->first = 0x22ae; };
  'nabla;' => { output->first = 0x2207; };
  'nacute;' => { output->first = 0x0144; };
  'nang;' => { output->first = 0x2220; output->second = 0x20d2; };
  'nap;' => { output->first = 0x2249; };
  'napE;' => { output->first = 0x2a70; output->second = 0x0338; };
  'napid;' => { output->first = 0x224b; output->second = 0x0338; };
  'napos;' => { output->first = 0x0149; };
  'napprox;' => { output->first = 0x2249; };
  'natur;' => { output->first = 0x266e; };
  'natural;' => { output->first = 0x266e; };
  'naturals;' => { output->first = 0x2115; };
  'nbsp;' => { output->first = 0xa0; };
  'nbsp' => { output->first = 0xa0; };
  'nbump;' => { output->first = 0x224e; output->second = 0x0338; };
  'nbumpe;' => { output->first = 0x224f; output->second = 0x0338; };
  'ncap;' => { output->first = 0x2a43; };
  'ncaron;' => { output->first = 0x0148; };
  'ncedil;' => { output->first = 0x0146; };
  'ncong;' => { output->first = 0x2247; };
  'ncongdot;' => { output->first = 0x2a6d; output->second = 0x0338; };
  'ncup;' => { output->first = 0x2a42; };
  'ncy;' => { output->first = 0x043d; };
  'ndash;' => { output->first = 0x2013; };
  'ne;' => { output->first = 0x2260; };
  'neArr;' => { output->first = 0x21d7; };
  'nearhk;' => { output->first = 0x2924; };
  'nearr;' => { output->first = 0x2197; };
  'nearrow;' => { output->first = 0x2197; };
  'nedot;' => { output->first = 0x2250; output->second = 0x0338; };
  'nequiv;' => { output->first = 0x2262; };
  'nesear;' => { output->first = 0x2928; };
  'nesim;' => { output->first = 0x2242; output->second = 0x0338; };
  'nexist;' => { output->first = 0x2204; };
  'nexists;' => { output->first = 0x2204; };
  'nfr;' => { output->first = 0x0001d52b; };
  'ngE;' => { output->first = 0x2267; output->second = 0x0338; };
  'nge;' => { output->first = 0x2271; };
  'ngeq;' => { output->first = 0x2271; };
  'ngeqq;' => { output->first = 0x2267; output->second = 0x0338; };
  'ngeqslant;' => { output->first = 0x2a7e; output->second = 0x0338; };
  'nges;' => { output->first = 0x2a7e; output->second = 0x0338; };
  'ngsim;' => { output->first = 0x2275; };
  'ngt;' => { output->first = 0x226f; };
  'ngtr;' => { output->first = 0x226f; };
  'nhArr;' => { output->first = 0x21ce; };
  'nharr;' => { output->first = 0x21ae; };
  'nhpar;' => { output->first = 0x2af2; };
  'ni;' => { output->first = 0x220b; };
  'nis;' => { output->first = 0x22fc; };
  'nisd;' => { output->first = 0x22fa; };
  'niv;' => { output->first = 0x220b; };
  'njcy;' => { output->first = 0x045a; };
  'nlArr;' => { output->first = 0x21cd; };
  'nlE;' => { output->first = 0x2266; output->second = 0x0338; };
  'nlarr;' => { output->first = 0x219a; };
  'nldr;' => { output->first = 0x2025; };
  'nle;' => { output->first = 0x2270; };
  'nleftarrow;' => { output->first = 0x219a; };
  'nleftrightarrow;' => { output->first = 0x21ae; };
  'nleq;' => { output->first = 0x2270; };
  'nleqq;' => { output->first = 0x2266; output->second = 0x0338; };
  'nleqslant;' => { output->first = 0x2a7d; output->second = 0x0338; };
  'nles;' => { output->first = 0x2a7d; output->second = 0x0338; };
  'nless;' => { output->first = 0x226e; };
  'nlsim;' => { output->first = 0x2274; };
  'nlt;' => { output->first = 0x226e; };
  'nltri;' => { output->first = 0x22ea; };
  'nltrie;' => { output->first = 0x22ec; };
  'nmid;' => { output->first = 0x2224; };
  'nopf;' => { output->first = 0x0001d55f; };
  'not;' => { output->first = 0xac; };
  'notin;' => { output->first = 0x2209; };
  'notinE;' => { output->first = 0x22f9; output->second = 0x0338; };
  'notindot;' => { output->first = 0x22f5; output->second = 0x0338; };
  'notinva;' => { output->first = 0x2209; };
  'notinvb;' => { output->first = 0x22f7; };
  'notinvc;' => { output->first = 0x22f6; };
  'notni;' => { output->first = 0x220c; };
  'notniva;' => { output->first = 0x220c; };
  'notnivb;' => { output->first = 0x22fe; };
  'notnivc;' => { output->first = 0x22fd; };
  'not' => { output->first = 0xac; };
  'npar;' => { output->first = 0x2226; };
  'nparallel;' => { output->first = 0x2226; };
  'nparsl;' => { output->first = 0x2afd; output->second = 0x20e5; };
  'npart;' => { output->first = 0x2202; output->second = 0x0338; };
  'npolint;' => { output->first = 0x2a14; };
  'npr;' => { output->first = 0x2280; };
  'nprcue;' => { output->first = 0x22e0; };
  'npre;' => { output->first = 0x2aaf; output->second = 0x0338; };
  'nprec;' => { output->first = 0x2280; };
  'npreceq;' => { output->first = 0x2aaf; output->second = 0x0338; };
  'nrArr;' => { output->first = 0x21cf; };
  'nrarr;' => { output->first = 0x219b; };
  'nrarrc;' => { output->first = 0x2933; output->second = 0x0338; };
  'nrarrw;' => { output->first = 0x219d; output->second = 0x0338; };
  'nrightarrow;' => { output->first = 0x219b; };
  'nrtri;' => { output->first = 0x22eb; };
  'nrtrie;' => { output->first = 0x22ed; };
  'nsc;' => { output->first = 0x2281; };
  'nsccue;' => { output->first = 0x22e1; };
  'nsce;' => { output->first = 0x2ab0; output->second = 0x0338; };
  'nscr;' => { output->first = 0x0001d4c3; };
  'nshortmid;' => { output->first = 0x2224; };
  'nshortparallel;' => { output->first = 0x2226; };
  'nsim;' => { output->first = 0x2241; };
  'nsime;' => { output->first = 0x2244; };
  'nsimeq;' => { output->first = 0x2244; };
  'nsmid;' => { output->first = 0x2224; };
  'nspar;' => { output->first = 0x2226; };
  'nsqsube;' => { output->first = 0x22e2; };
  'nsqsupe;' => { output->first = 0x22e3; };
  'nsub;' => { output->first = 0x2284; };
  'nsubE;' => { output->first = 0x2ac5; output->second = 0x0338; };
  'nsube;' => { output->first = 0x2288; };
  'nsubset;' => { output->first = 0x2282; output->second = 0x20d2; };
  'nsubseteq;' => { output->first = 0x2288; };
  'nsubseteqq;' => { output->first = 0x2ac5; output->second = 0x0338; };
  'nsucc;' => { output->first = 0x2281; };
  'nsucceq;' => { output->first = 0x2ab0; output->second = 0x0338; };
  'nsup;' => { output->first = 0x2285; };
  'nsupE;' => { output->first = 0x2ac6; output->second = 0x0338; };
  'nsupe;' => { output->first = 0x2289; };
  'nsupset;' => { output->first = 0x2283; output->second = 0x20d2; };
  'nsupseteq;' => { output->first = 0x2289; };
  'nsupseteqq;' => { output->first = 0x2ac6; output->second = 0x0338; };
  'ntgl;' => { output->first = 0x2279; };
  'ntilde;' => { output->first = 0xf1; };
  'ntilde' => { output->first = 0xf1; };
  'ntlg;' => { output->first = 0x2278; };
  'ntriangleleft;' => { output->first = 0x22ea; };
  'ntrianglelefteq;' => { output->first = 0x22ec; };
  'ntriangleright;' => { output->first = 0x22eb; };
  'ntrianglerighteq;' => { output->first = 0x22ed; };
  'nu;' => { output->first = 0x03bd; };
  'num;' => { output->first = 0x23; };
  'numero;' => { output->first = 0x2116; };
  'numsp;' => { output->first = 0x2007; };
  'nvDash;' => { output->first = 0x22ad; };
  'nvHarr;' => { output->first = 0x2904; };
  'nvap;' => { output->first = 0x224d; output->second = 0x20d2; };
  'nvdash;' => { output->first = 0x22ac; };
  'nvge;' => { output->first = 0x2265; output->second = 0x20d2; };
  'nvgt;' => { output->first = 0x3e; output->second = 0x20d2; };
  'nvinfin;' => { output->first = 0x29de; };
  'nvlArr;' => { output->first = 0x2902; };
  'nvle;' => { output->first = 0x2264; output->second = 0x20d2; };
  'nvlt;' => { output->first = 0x3c; output->second = 0x20d2; };
  'nvltrie;' => { output->first = 0x22b4; output->second = 0x20d2; };
  'nvrArr;' => { output->first = 0x2903; };
  'nvrtrie;' => { output->first = 0x22b5; output->second = 0x20d2; };
  'nvsim;' => { output->first = 0x223c; output->second = 0x20d2; };
  'nwArr;' => { output->first = 0x21d6; };
  'nwarhk;' => { output->first = 0x2923; };
  'nwarr;' => { output->first = 0x2196; };
  'nwarrow;' => { output->first = 0x2196; };
  'nwnear;' => { output->first = 0x2927; };
  'oS;' => { output->first = 0x24c8; };
  'oacute;' => { output->first = 0xf3; };
  'oacute' => { output->first = 0xf3; };
  'oast;' => { output->first = 0x229b; };
  'ocir;' => { output->first = 0x229a; };
  'ocirc;' => { output->first = 0xf4; };
  'ocirc' => { output->first = 0xf4; };
  'ocy;' => { output->first = 0x043e; };
  'odash;' => { output->first = 0x229d; };
  'odblac;' => { output->first = 0x0151; };
  'odiv;' => { output->first = 0x2a38; };
  'odot;' => { output->first = 0x2299; };
  'odsold;' => { output->first = 0x29bc; };
  'oelig;' => { output->first = 0x0153; };
  'ofcir;' => { output->first = 0x29bf; };
  'ofr;' => { output->first = 0x0001d52c; };
  'ogon;' => { output->first = 0x02db; };
  'ograve;' => { output->first = 0xf2; };
  'ograve' => { output->first = 0xf2; };
  'ogt;' => { output->first = 0x29c1; };
  'ohbar;' => { output->first = 0x29b5; };
  'ohm;' => { output->first = 0x03a9; };
  'oint;' => { output->first = 0x222e; };
  'olarr;' => { output->first = 0x21ba; };
  'olcir;' => { output->first = 0x29be; };
  'olcross;' => { output->first = 0x29bb; };
  'oline;' => { output->first = 0x203e; };
  'olt;' => { output->first = 0x29c0; };
  'omacr;' => { output->first = 0x014d; };
  'omega;' => { output->first = 0x03c9; };
  'omicron;' => { output->first = 0x03bf; };
  'omid;' => { output->first = 0x29b6; };
  'ominus;' => { output->first = 0x2296; };
  'oopf;' => { output->first = 0x0001d560; };
  'opar;' => { output->first = 0x29b7; };
  'operp;' => { output->first = 0x29b9; };
  'oplus;' => { output->first = 0x2295; };
  'or;' => { output->first = 0x2228; };
  'orarr;' => { output->first = 0x21bb; };
  'ord;' => { output->first = 0x2a5d; };
  'order;' => { output->first = 0x2134; };
  'orderof;' => { output->first = 0x2134; };
  'ordf;' => { output->first = 0xaa; };
  'ordf' => { output->first = 0xaa; };
  'ordm;' => { output->first = 0xba; };
  'ordm' => { output->first = 0xba; };
  'origof;' => { output->first = 0x22b6; };
  'oror;' => { output->first = 0x2a56; };
  'orslope;' => { output->first = 0x2a57; };
  'orv;' => { output->first = 0x2a5b; };
  'oscr;' => { output->first = 0x2134; };
  'oslash;' => { output->first = 0xf8; };
  'oslash' => { output->first = 0xf8; };
  'osol;' => { output->first = 0x2298; };
  'otilde;' => { output->first = 0xf5; };
  'otilde' => { output->first = 0xf5; };
  'otimes;' => { output->first = 0x2297; };
  'otimesas;' => { output->first = 0x2a36; };
  'ouml;' => { output->first = 0xf6; };
  'ouml' => { output->first = 0xf6; };
  'ovbar;' => { output->first = 0x233d; };
  'par;' => { output->first = 0x2225; };
  'para;' => { output->first = 0xb6; };
  'para' => { output->first = 0xb6; };
  'parallel;' => { output->first = 0x2225; };
  'parsim;' => { output->first = 0x2af3; };
  'parsl;' => { output->first = 0x2afd; };
  'part;' => { output->first = 0x2202; };
  'pcy;' => { output->first = 0x043f; };
  'percnt;' => { output->first = 0x25; };
  'period;' => { output->first = 0x2e; };
  'permil;' => { output->first = 0x2030; };
  'perp;' => { output->first = 0x22a5; };
  'pertenk;' => { output->first = 0x2031; };
  'pfr;' => { output->first = 0x0001d52d; };
  'phi;' => { output->first = 0x03c6; };
  'phiv;' => { output->first = 0x03d5; };
  'phmmat;' => { output->first = 0x2133; };
  'phone;' => { output->first = 0x260e; };
  'pi;' => { output->first = 0x03c0; };
  'pitchfork;' => { output->first = 0x22d4; };
  'piv;' => { output->first = 0x03d6; };
  'planck;' => { output->first = 0x210f; };
  'planckh;' => { output->first = 0x210e; };
  'plankv;' => { output->first = 0x210f; };
  'plus;' => { output->first = 0x2b; };
  'plusacir;' => { output->first = 0x2a23; };
  'plusb;' => { output->first = 0x229e; };
  'pluscir;' => { output->first = 0x2a22; };
  'plusdo;' => { output->first = 0x2214; };
  'plusdu;' => { output->first = 0x2a25; };
  'pluse;' => { output->first = 0x2a72; };
  'plusmn;' => { output->first = 0xb1; };
  'plusmn' => { output->first = 0xb1; };
  'plussim;' => { output->first = 0x2a26; };
  'plustwo;' => { output->first = 0x2a27; };
  'pm;' => { output->first = 0xb1; };
  'pointint;' => { output->first = 0x2a15; };
  'popf;' => { output->first = 0x0001d561; };
  'pound;' => { output->first = 0xa3; };
  'pound' => { output->first = 0xa3; };
  'pr;' => { output->first = 0x227a; };
  'prE;' => { output->first = 0x2ab3; };
  'prap;' => { output->first = 0x2ab7; };
  'prcue;' => { output->first = 0x227c; };
  'pre;' => { output->first = 0x2aaf; };
  'prec;' => { output->first = 0x227a; };
  'precapprox;' => { output->first = 0x2ab7; };
  'preccurlyeq;' => { output->first = 0x227c; };
  'preceq;' => { output->first = 0x2aaf; };
  'precnapprox;' => { output->first = 0x2ab9; };
  'precneqq;' => { output->first = 0x2ab5; };
  'precnsim;' => { output->first = 0x22e8; };
  'precsim;' => { output->first = 0x227e; };
  'prime;' => { output->first = 0x2032; };
  'primes;' => { output->first = 0x2119; };
  'prnE;' => { output->first = 0x2ab5; };
  'prnap;' => { output->first = 0x2ab9; };
  'prnsim;' => { output->first = 0x22e8; };
  'prod;' => { output->first = 0x220f; };
  'profalar;' => { output->first = 0x232e; };
  'profline;' => { output->first = 0x2312; };
  'profsurf;' => { output->first = 0x2313; };
  'prop;' => { output->first = 0x221d; };
  'propto;' => { output->first = 0x221d; };
  'prsim;' => { output->first = 0x227e; };
  'prurel;' => { output->first = 0x22b0; };
  'pscr;' => { output->first = 0x0001d4c5; };
  'psi;' => { output->first = 0x03c8; };
  'puncsp;' => { output->first = 0x2008; };
  'qfr;' => { output->first = 0x0001d52e; };
  'qint;' => { output->first = 0x2a0c; };
  'qopf;' => { output->first = 0x0001d562; };
  'qprime;' => { output->first = 0x2057; };
  'qscr;' => { output->first = 0x0001d4c6; };
  'quaternions;' => { output->first = 0x210d; };
  'quatint;' => { output->first = 0x2a16; };
  'quest;' => { output->first = 0x3f; };
  'questeq;' => { output->first = 0x225f; };
  'quot;' => { output->first = 0x22; };
  'quot' => { output->first = 0x22; };
  'rAarr;' => { output->first = 0x21db; };
  'rArr;' => { output->first = 0x21d2; };
  'rAtail;' => { output->first = 0x291c; };
  'rBarr;' => { output->first = 0x290f; };
  'rHar;' => { output->first = 0x2964; };
  'race;' => { output->first = 0x223d; output->second = 0x0331; };
  'racute;' => { output->first = 0x0155; };
  'radic;' => { output->first = 0x221a; };
  'raemptyv;' => { output->first = 0x29b3; };
  'rang;' => { output->first = 0x27e9; };
  'rangd;' => { output->first = 0x2992; };
  'range;' => { output->first = 0x29a5; };
  'rangle;' => { output->first = 0x27e9; };
  'raquo;' => { output->first = 0xbb; };
  'raquo' => { output->first = 0xbb; };
  'rarr;' => { output->first = 0x2192; };
  'rarrap;' => { output->first = 0x2975; };
  'rarrb;' => { output->first = 0x21e5; };
  'rarrbfs;' => { output->first = 0x2920; };
  'rarrc;' => { output->first = 0x2933; };
  'rarrfs;' => { output->first = 0x291e; };
  'rarrhk;' => { output->first = 0x21aa; };
  'rarrlp;' => { output->first = 0x21ac; };
  'rarrpl;' => { output->first = 0x2945; };
  'rarrsim;' => { output->first = 0x2974; };
  'rarrtl;' => { output->first = 0x21a3; };
  'rarrw;' => { output->first = 0x219d; };
  'ratail;' => { output->first = 0x291a; };
  'ratio;' => { output->first = 0x2236; };
  'rationals;' => { output->first = 0x211a; };
  'rbarr;' => { output->first = 0x290d; };
  'rbbrk;' => { output->first = 0x2773; };
  'rbrace;' => { output->first = 0x7d; };
  'rbrack;' => { output->first = 0x5d; };
  'rbrke;' => { output->first = 0x298c; };
  'rbrksld;' => { output->first = 0x298e; };
  'rbrkslu;' => { output->first = 0x2990; };
  'rcaron;' => { output->first = 0x0159; };
  'rcedil;' => { output->first = 0x0157; };
  'rceil;' => { output->first = 0x2309; };
  'rcub;' => { output->first = 0x7d; };
  'rcy;' => { output->first = 0x0440; };
  'rdca;' => { output->first = 0x2937; };
  'rdldhar;' => { output->first = 0x2969; };
  'rdquo;' => { output->first = 0x201d; };
  'rdquor;' => { output->first = 0x201d; };
  'rdsh;' => { output->first = 0x21b3; };
  'real;' => { output->first = 0x211c; };
  'realine;' => { output->first = 0x211b; };
  'realpart;' => { output->first = 0x211c; };
  'reals;' => { output->first = 0x211d; };
  'rect;' => { output->first = 0x25ad; };
  'reg;' => { output->first = 0xae; };
  'reg' => { output->first = 0xae; };
  'rfisht;' => { output->first = 0x297d; };
  'rfloor;' => { output->first = 0x230b; };
  'rfr;' => { output->first = 0x0001d52f; };
  'rhard;' => { output->first = 0x21c1; };
  'rharu;' => { output->first = 0x21c0; };
  'rharul;' => { output->first = 0x296c; };
  'rho;' => { output->first = 0x03c1; };
  'rhov;' => { output->first = 0x03f1; };
  'rightarrow;' => { output->first = 0x2192; };
  'rightarrowtail;' => { output->first = 0x21a3; };
  'rightharpoondown;' => { output->first = 0x21c1; };
  'rightharpoonup;' => { output->first = 0x21c0; };
  'rightleftarrows;' => { output->first = 0x21c4; };
  'rightleftharpoons;' => { output->first = 0x21cc; };
  'rightrightarrows;' => { output->first = 0x21c9; };
  'rightsquigarrow;' => { output->first = 0x219d; };
  'rightthreetimes;' => { output->first = 0x22cc; };
  'ring;' => { output->first = 0x02da; };
  'risingdotseq;' => { output->first = 0x2253; };
  'rlarr;' => { output->first = 0x21c4; };
  'rlhar;' => { output->first = 0x21cc; };
  'rlm;' => { output->first = 0x200f; };
  'rmoust;' => { output->first = 0x23b1; };
  'rmoustache;' => { output->first = 0x23b1; };
  'rnmid;' => { output->first = 0x2aee; };
  'roang;' => { output->first = 0x27ed; };
  'roarr;' => { output->first = 0x21fe; };
  'robrk;' => { output->first = 0x27e7; };
  'ropar;' => { output->first = 0x2986; };
  'ropf;' => { output->first = 0x0001d563; };
  'roplus;' => { output->first = 0x2a2e; };
  'rotimes;' => { output->first = 0x2a35; };
  'rpar;' => { output->first = 0x29; };
  'rpargt;' => { output->first = 0x2994; };
  'rppolint;' => { output->first = 0x2a12; };
  'rrarr;' => { output->first = 0x21c9; };
  'rsaquo;' => { output->first = 0x203a; };
  'rscr;' => { output->first = 0x0001d4c7; };
  'rsh;' => { output->first = 0x21b1; };
  'rsqb;' => { output->first = 0x5d; };
  'rsquo;' => { output->first = 0x2019; };
  'rsquor;' => { output->first = 0x2019; };
  'rthree;' => { output->first = 0x22cc; };
  'rtimes;' => { output->first = 0x22ca; };
  'rtri;' => { output->first = 0x25b9; };
  'rtrie;' => { output->first = 0x22b5; };
  'rtrif;' => { output->first = 0x25b8; };
  'rtriltri;' => { output->first = 0x29ce; };
  'ruluhar;' => { output->first = 0x2968; };
  'rx;' => { output->first = 0x211e; };
  'sacute;' => { output->first = 0x015b; };
  'sbquo;' => { output->first = 0x201a; };
  'sc;' => { output->first = 0x227b; };
  'scE;' => { output->first = 0x2ab4; };
  'scap;' => { output->first = 0x2ab8; };
  'scaron;' => { output->first = 0x0161; };
  'sccue;' => { output->first = 0x227d; };
  'sce;' => { output->first = 0x2ab0; };
  'scedil;' => { output->first = 0x015f; };
  'scirc;' => { output->first = 0x015d; };
  'scnE;' => { output->first = 0x2ab6; };
  'scnap;' => { output->first = 0x2aba; };
  'scnsim;' => { output->first = 0x22e9; };
  'scpolint;' => { output->first = 0x2a13; };
  'scsim;' => { output->first = 0x227f; };
  'scy;' => { output->first = 0x0441; };
  'sdot;' => { output->first = 0x22c5; };
  'sdotb;' => { output->first = 0x22a1; };
  'sdote;' => { output->first = 0x2a66; };
  'seArr;' => { output->first = 0x21d8; };
  'searhk;' => { output->first = 0x2925; };
  'searr;' => { output->first = 0x2198; };
  'searrow;' => { output->first = 0x2198; };
  'sect;' => { output->first = 0xa7; };
  'sect' => { output->first = 0xa7; };
  'semi;' => { output->first = 0x3b; };
  'seswar;' => { output->first = 0x2929; };
  'setminus;' => { output->first = 0x2216; };
  'setmn;' => { output->first = 0x2216; };
  'sext;' => { output->first = 0x2736; };
  'sfr;' => { output->first = 0x0001d530; };
  'sfrown;' => { output->first = 0x2322; };
  'sharp;' => { output->first = 0x266f; };
  'shchcy;' => { output->first = 0x0449; };
  'shcy;' => { output->first = 0x0448; };
  'shortmid;' => { output->first = 0x2223; };
  'shortparallel;' => { output->first = 0x2225; };
  'shy;' => { output->first = 0xad; };
  'shy' => { output->first = 0xad; };
  'sigma;' => { output->first = 0x03c3; };
  'sigmaf;' => { output->first = 0x03c2; };
  'sigmav;' => { output->first = 0x03c2; };
  'sim;' => { output->first = 0x223c; };
  'simdot;' => { output->first = 0x2a6a; };
  'sime;' => { output->first = 0x2243; };
  'simeq;' => { output->first = 0x2243; };
  'simg;' => { output->first = 0x2a9e; };
  'simgE;' => { output->first = 0x2aa0; };
  'siml;' => { output->first = 0x2a9d; };
  'simlE;' => { output->first = 0x2a9f; };
  'simne;' => { output->first = 0x2246; };
  'simplus;' => { output->first = 0x2a24; };
  'simrarr;' => { output->first = 0x2972; };
  'slarr;' => { output->first = 0x2190; };
  'smallsetminus;' => { output->first = 0x2216; };
  'smashp;' => { output->first = 0x2a33; };
  'smeparsl;' => { output->first = 0x29e4; };
  'smid;' => { output->first = 0x2223; };
  'smile;' => { output->first = 0x2323; };
  'smt;' => { output->first = 0x2aaa; };
  'smte;' => { output->first = 0x2aac; };
  'smtes;' => { output->first = 0x2aac; output->second = 0xfe00; };
  'softcy;' => { output->first = 0x044c; };
  'sol;' => { output->first = 0x2f; };
  'solb;' => { output->first = 0x29c4; };
  'solbar;' => { output->first = 0x233f; };
  'sopf;' => { output->first = 0x0001d564; };
  'spades;' => { output->first = 0x2660; };
  'spadesuit;' => { output->first = 0x2660; };
  'spar;' => { output->first = 0x2225; };
  'sqcap;' => { output->first = 0x2293; };
  'sqcaps;' => { output->first = 0x2293; output->second = 0xfe00; };
  'sqcup;' => { output->first = 0x2294; };
  'sqcups;' => { output->first = 0x2294; output->second = 0xfe00; };
  'sqsub;' => { output->first = 0x228f; };
  'sqsube;' => { output->first = 0x2291; };
  'sqsubset;' => { output->first = 0x228f; };
  'sqsubseteq;' => { output->first = 0x2291; };
  'sqsup;' => { output->first = 0x2290; };
  'sqsupe;' => { output->first = 0x2292; };
  'sqsupset;' => { output->first = 0x2290; };
  'sqsupseteq;' => { output->first = 0x2292; };
  'squ;' => { output->first = 0x25a1; };
  'square;' => { output->first = 0x25a1; };
  'squarf;' => { output->first = 0x25aa; };
  'squf;' => { output->first = 0x25aa; };
  'srarr;' => { output->first = 0x2192; };
  'sscr;' => { output->first = 0x0001d4c8; };
  'ssetmn;' => { output->first = 0x2216; };
  'ssmile;' => { output->first = 0x2323; };
  'sstarf;' => { output->first = 0x22c6; };
  'star;' => { output->first = 0x2606; };
  'starf;' => { output->first = 0x2605; };
  'straightepsilon;' => { output->first = 0x03f5; };
  'straightphi;' => { output->first = 0x03d5; };
  'strns;' => { output->first = 0xaf; };
  'sub;' => { output->first = 0x2282; };
  'subE;' => { output->first = 0x2ac5; };
  'subdot;' => { output->first = 0x2abd; };
  'sube;' => { output->first = 0x2286; };
  'subedot;' => { output->first = 0x2ac3; };
  'submult;' => { output->first = 0x2ac1; };
  'subnE;' => { output->first = 0x2acb; };
  'subne;' => { output->first = 0x228a; };
  'subplus;' => { output->first = 0x2abf; };
  'subrarr;' => { output->first = 0x2979; };
  'subset;' => { output->first = 0x2282; };
  'subseteq;' => { output->first = 0x2286; };
  'subseteqq;' => { output->first = 0x2ac5; };
  'subsetneq;' => { output->first = 0x228a; };
  'subsetneqq;' => { output->first = 0x2acb; };
  'subsim;' => { output->first = 0x2ac7; };
  'subsub;' => { output->first = 0x2ad5; };
  'subsup;' => { output->first = 0x2ad3; };
  'succ;' => { output->first = 0x227b; };
  'succapprox;' => { output->first = 0x2ab8; };
  'succcurlyeq;' => { output->first = 0x227d; };
  'succeq;' => { output->first = 0x2ab0; };
  'succnapprox;' => { output->first = 0x2aba; };
  'succneqq;' => { output->first = 0x2ab6; };
  'succnsim;' => { output->first = 0x22e9; };
  'succsim;' => { output->first = 0x227f; };
  'sum;' => { output->first = 0x2211; };
  'sung;' => { output->first = 0x266a; };
  'sup1;' => { output->first = 0xb9; };
  'sup1' => { output->first = 0xb9; };
  'sup2;' => { output->first = 0xb2; };
  'sup2' => { output->first = 0xb2; };
  'sup3;' => { output->first = 0xb3; };
  'sup3' => { output->first = 0xb3; };
  'sup;' => { output->first = 0x2283; };
  'supE;' => { output->first = 0x2ac6; };
  'supdot;' => { output->first = 0x2abe; };
  'supdsub;' => { output->first = 0x2ad8; };
  'supe;' => { output->first = 0x2287; };
  'supedot;' => { output->first = 0x2ac4; };
  'suphsol;' => { output->first = 0x27c9; };
  'suphsub;' => { output->first = 0x2ad7; };
  'suplarr;' => { output->first = 0x297b; };
  'supmult;' => { output->first = 0x2ac2; };
  'supnE;' => { output->first = 0x2acc; };
  'supne;' => { output->first = 0x228b; };
  'supplus;' => { output->first = 0x2ac0; };
  'supset;' => { output->first = 0x2283; };
  'supseteq;' => { output->first = 0x2287; };
  'supseteqq;' => { output->first = 0x2ac6; };
  'supsetneq;' => { output->first = 0x228b; };
  'supsetneqq;' => { output->first = 0x2acc; };
  'supsim;' => { output->first = 0x2ac8; };
  'supsub;' => { output->first = 0x2ad4; };
  'supsup;' => { output->first = 0x2ad6; };
  'swArr;' => { output->first = 0x21d9; };
  'swarhk;' => { output->first = 0x2926; };
  'swarr;' => { output->first = 0x2199; };
  'swarrow;' => { output->first = 0x2199; };
  'swnwar;' => { output->first = 0x292a; };
  'szlig;' => { output->first = 0xdf; };
  'szlig' => { output->first = 0xdf; };
  'target;' => { output->first = 0x2316; };
  'tau;' => { output->first = 0x03c4; };
  'tbrk;' => { output->first = 0x23b4; };
  'tcaron;' => { output->first = 0x0165; };
  'tcedil;' => { output->first = 0x0163; };
  'tcy;' => { output->first = 0x0442; };
  'tdot;' => { output->first = 0x20db; };
  'telrec;' => { output->first = 0x2315; };
  'tfr;' => { output->first = 0x0001d531; };
  'there4;' => { output->first = 0x2234; };
  'therefore;' => { output->first = 0x2234; };
  'theta;' => { output->first = 0x03b8; };
  'thetasym;' => { output->first = 0x03d1; };
  'thetav;' => { output->first = 0x03d1; };
  'thickapprox;' => { output->first = 0x2248; };
  'thicksim;' => { output->first = 0x223c; };
  'thinsp;' => { output->first = 0x2009; };
  'thkap;' => { output->first = 0x2248; };
  'thksim;' => { output->first = 0x223c; };
  'thorn;' => { output->first = 0xfe; };
  'thorn' => { output->first = 0xfe; };
  'tilde;' => { output->first = 0x02dc; };
  'times;' => { output->first = 0xd7; };
  'times' => { output->first = 0xd7; };
  'timesb;' => { output->first = 0x22a0; };
  'timesbar;' => { output->first = 0x2a31; };
  'timesd;' => { output->first = 0x2a30; };
  'tint;' => { output->first = 0x222d; };
  'toea;' => { output->first = 0x2928; };
  'top;' => { output->first = 0x22a4; };
  'topbot;' => { output->first = 0x2336; };
  'topcir;' => { output->first = 0x2af1; };
  'topf;' => { output->first = 0x0001d565; };
  'topfork;' => { output->first = 0x2ada; };
  'tosa;' => { output->first = 0x2929; };
  'tprime;' => { output->first = 0x2034; };
  'trade;' => { output->first = 0x2122; };
  'triangle;' => { output->first = 0x25b5; };
  'triangledown;' => { output->first = 0x25bf; };
  'triangleleft;' => { output->first = 0x25c3; };
  'trianglelefteq;' => { output->first = 0x22b4; };
  'triangleq;' => { output->first = 0x225c; };
  'triangleright;' => { output->first = 0x25b9; };
  'trianglerighteq;' => { output->first = 0x22b5; };
  'tridot;' => { output->first = 0x25ec; };
  'trie;' => { output->first = 0x225c; };
  'triminus;' => { output->first = 0x2a3a; };
  'triplus;' => { output->first = 0x2a39; };
  'trisb;' => { output->first = 0x29cd; };
  'tritime;' => { output->first = 0x2a3b; };
  'trpezium;' => { output->first = 0x23e2; };
  'tscr;' => { output->first = 0x0001d4c9; };
  'tscy;' => { output->first = 0x0446; };
  'tshcy;' => { output->first = 0x045b; };
  'tstrok;' => { output->first = 0x0167; };
  'twixt;' => { output->first = 0x226c; };
  'twoheadleftarrow;' => { output->first = 0x219e; };
  'twoheadrightarrow;' => { output->first = 0x21a0; };
  'uArr;' => { output->first = 0x21d1; };
  'uHar;' => { output->first = 0x2963; };
  'uacute;' => { output->first = 0xfa; };
  'uacute' => { output->first = 0xfa; };
  'uarr;' => { output->first = 0x2191; };
  'ubrcy;' => { output->first = 0x045e; };
  'ubreve;' => { output->first = 0x016d; };
  'ucirc;' => { output->first = 0xfb; };
  'ucirc' => { output->first = 0xfb; };
  'ucy;' => { output->first = 0x0443; };
  'udarr;' => { output->first = 0x21c5; };
  'udblac;' => { output->first = 0x0171; };
  'udhar;' => { output->first = 0x296e; };
  'ufisht;' => { output->first = 0x297e; };
  'ufr;' => { output->first = 0x0001d532; };
  'ugrave;' => { output->first = 0xf9; };
  'ugrave' => { output->first = 0xf9; };
  'uharl;' => { output->first = 0x21bf; };
  'uharr;' => { output->first = 0x21be; };
  'uhblk;' => { output->first = 0x2580; };
  'ulcorn;' => { output->first = 0x231c; };
  'ulcorner;' => { output->first = 0x231c; };
  'ulcrop;' => { output->first = 0x230f; };
  'ultri;' => { output->first = 0x25f8; };
  'umacr;' => { output->first = 0x016b; };
  'uml;' => { output->first = 0xa8; };
  'uml' => { output->first = 0xa8; };
  'uogon;' => { output->first = 0x0173; };
  'uopf;' => { output->first = 0x0001d566; };
  'uparrow;' => { output->first = 0x2191; };
  'updownarrow;' => { output->first = 0x2195; };
  'upharpoonleft;' => { output->first = 0x21bf; };
  'upharpoonright;' => { output->first = 0x21be; };
  'uplus;' => { output->first = 0x228e; };
  'upsi;' => { output->first = 0x03c5; };
  'upsih;' => { output->first = 0x03d2; };
  'upsilon;' => { output->first = 0x03c5; };
  'upuparrows;' => { output->first = 0x21c8; };
  'urcorn;' => { output->first = 0x231d; };
  'urcorner;' => { output->first = 0x231d; };
  'urcrop;' => { output->first = 0x230e; };
  'uring;' => { output->first = 0x016f; };
  'urtri;' => { output->first = 0x25f9; };
  'uscr;' => { output->first = 0x0001d4ca; };
  'utdot;' => { output->first = 0x22f0; };
  'utilde;' => { output->first = 0x0169; };
  'utri;' => { output->first = 0x25b5; };
  'utrif;' => { output->first = 0x25b4; };
  'uuarr;' => { output->first = 0x21c8; };
  'uuml;' => { output->first = 0xfc; };
  'uuml' => { output->first = 0xfc; };
  'uwangle;' => { output->first = 0x29a7; };
  'vArr;' => { output->first = 0x21d5; };
  'vBar;' => { output->first = 0x2ae8; };
  'vBarv;' => { output->first = 0x2ae9; };
  'vDash;' => { output->first = 0x22a8; };
  'vangrt;' => { output->first = 0x299c; };
  'varepsilon;' => { output->first = 0x03f5; };
  'varkappa;' => { output->first = 0x03f0; };
  'varnothing;' => { output->first = 0x2205; };
  'varphi;' => { output->first = 0x03d5; };
  'varpi;' => { output->first = 0x03d6; };
  'varpropto;' => { output->first = 0x221d; };
  'varr;' => { output->first = 0x2195; };
  'varrho;' => { output->first = 0x03f1; };
  'varsigma;' => { output->first = 0x03c2; };
  'varsubsetneq;' => { output->first = 0x228a; output->second = 0xfe00; };
  'varsubsetneqq;' => { output->first = 0x2acb; output->second = 0xfe00; };
  'varsupsetneq;' => { output->first = 0x228b; output->second = 0xfe00; };
  'varsupsetneqq;' => { output->first = 0x2acc; output->second = 0xfe00; };
  'vartheta;' => { output->first = 0x03d1; };
  'vartriangleleft;' => { output->first = 0x22b2; };
  'vartriangleright;' => { output->first = 0x22b3; };
  'vcy;' => { output->first = 0x0432; };
  'vdash;' => { output->first = 0x22a2; };
  'vee;' => { output->first = 0x2228; };
  'veebar;' => { output->first = 0x22bb; };
  'veeeq;' => { output->first = 0x225a; };
  'vellip;' => { output->first = 0x22ee; };
  'verbar;' => { output->first = 0x7c; };
  'vert;' => { output->first = 0x7c; };
  'vfr;' => { output->first = 0x0001d533; };
  'vltri;' => { output->first = 0x22b2; };
  'vnsub;' => { output->first = 0x2282; output->second = 0x20d2; };
  'vnsup;' => { output->first = 0x2283; output->second = 0x20d2; };
  'vopf;' => { output->first = 0x0001d567; };
  'vprop;' => { output->first = 0x221d; };
  'vrtri;' => { output->first = 0x22b3; };
  'vscr;' => { output->first = 0x0001d4cb; };
  'vsubnE;' => { output->first = 0x2acb; output->second = 0xfe00; };
  'vsubne;' => { output->first = 0x228a; output->second = 0xfe00; };
  'vsupnE;' => { output->first = 0x2acc; output->second = 0xfe00; };
  'vsupne;' => { output->first = 0x228b; output->second = 0xfe00; };
  'vzigzag;' => { output->first = 0x299a; };
  'wcirc;' => { output->first = 0x0175; };
  'wedbar;' => { output->first = 0x2a5f; };
  'wedge;' => { output->first = 0x2227; };
  'wedgeq;' => { output->first = 0x2259; };
  'weierp;' => { output->first = 0x2118; };
  'wfr;' => { output->first = 0x0001d534; };
  'wopf;' => { output->first = 0x0001d568; };
  'wp;' => { output->first = 0x2118; };
  'wr;' => { output->first = 0x2240; };
  'wreath;' => { output->first = 0x2240; };
  'wscr;' => { output->first = 0x0001d4cc; };
  'xcap;' => { output->first = 0x22c2; };
  'xcirc;' => { output->first = 0x25ef; };
  'xcup;' => { output->first = 0x22c3; };
  'xdtri;' => { output->first = 0x25bd; };
  'xfr;' => { output->first = 0x0001d535; };
  'xhArr;' => { output->first = 0x27fa; };
  'xharr;' => { output->first = 0x27f7; };
  'xi;' => { output->first = 0x03be; };
  'xlArr;' => { output->first = 0x27f8; };
  'xlarr;' => { output->first = 0x27f5; };
  'xmap;' => { output->first = 0x27fc; };
  'xnis;' => { output->first = 0x22fb; };
  'xodot;' => { output->first = 0x2a00; };
  'xopf;' => { output->first = 0x0001d569; };
  'xoplus;' => { output->first = 0x2a01; };
  'xotime;' => { output->first = 0x2a02; };
  'xrArr;' => { output->first = 0x27f9; };
  'xrarr;' => { output->first = 0x27f6; };
  'xscr;' => { output->first = 0x0001d4cd; };
  'xsqcup;' => { output->first = 0x2a06; };
  'xuplus;' => { output->first = 0x2a04; };
  'xutri;' => { output->first = 0x25b3; };
  'xvee;' => { output->first = 0x22c1; };
  'xwedge;' => { output->first = 0x22c0; };
  'yacute;' => { output->first = 0xfd; };
  'yacute' => { output->first = 0xfd; };
  'yacy;' => { output->first = 0x044f; };
  'ycirc;' => { output->first = 0x0177; };
  'ycy;' => { output->first = 0x044b; };
  'yen;' => { output->first = 0xa5; };
  'yen' => { output->first = 0xa5; };
  'yfr;' => { output->first = 0x0001d536; };
  'yicy;' => { output->first = 0x0457; };
  'yopf;' => { output->first = 0x0001d56a; };
  'yscr;' => { output->first = 0x0001d4ce; };
  'yucy;' => { output->first = 0x044e; };
  'yuml;' => { output->first = 0xff; };
  'yuml' => { output->first = 0xff; };
  'zacute;' => { output->first = 0x017a; };
  'zcaron;' => { output->first = 0x017e; };
  'zcy;' => { output->first = 0x0437; };
  'zdot;' => { output->first = 0x017c; };
  'zeetrf;' => { output->first = 0x2128; };
  'zeta;' => { output->first = 0x03b6; };
  'zfr;' => { output->first = 0x0001d537; };
  'zhcy;' => { output->first = 0x0436; };
  'zigrarr;' => { output->first = 0x21dd; };
  'zopf;' => { output->first = 0x0001d56b; };
  'zscr;' => { output->first = 0x0001d4cf; };
  'zwj;' => { output->first = 0x200d; };
  'zwnj;' => { output->first = 0x200c; };
*|;
}%%

%% write data;

static bool consume_named_ref(
    struct GumboInternalParser* parser, Utf8Iterator* input, bool is_in_attribute,
    OneOrTwoCodepoints* output) {
  assert(output->first == kGumboNoChar);
  const char* p = utf8iterator_get_char_pointer(input);
  const char* pe = utf8iterator_get_end_pointer(input);
  const char* eof = pe;
  const char* te = 0;
  const char *ts, *start;
  int cs, act;

  %% write init;
  // Avoid unused variable warnings.
  (void) act;
  (void) ts;

  start = p;
  %% write exec;

  if (output->first != kGumboNoChar) {
    char last_char = *(te - 1);
    int len = te - start;
    if (last_char == ';') {
      bool matched = utf8iterator_maybe_consume_match(input, start, len, true);
      assert(matched);
      return true;
    } else if (is_in_attribute && is_legal_attribute_char_next(input)) {
      output->first = kGumboNoChar;
      output->second = kGumboNoChar;
      utf8iterator_reset(input);
      return true;
    } else {
      GumboStringPiece bad_ref;
      bad_ref.length = te - start;
      bad_ref.data = start;
      add_named_reference_error(
          parser, input, GUMBO_ERR_NAMED_CHAR_REF_WITHOUT_SEMICOLON, bad_ref);
      assert(output->first != kGumboNoChar);
      bool matched = utf8iterator_maybe_consume_match(input, start, len, true);
      assert(matched);
      return false;
    }
  } else {
    bool status = maybe_add_invalid_named_reference(parser, input);
    utf8iterator_reset(input);
    return status;
  }
}

bool consume_char_ref(
    struct GumboInternalParser* parser, struct GumboInternalUtf8Iterator* input,
    int additional_allowed_char, bool is_in_attribute,
    OneOrTwoCodepoints* output) {
  utf8iterator_mark(input);
  utf8iterator_next(input);
  int c = utf8iterator_current(input);
  output->first = kGumboNoChar;
  output->second = kGumboNoChar;
  if (c == additional_allowed_char) {
    utf8iterator_reset(input);
    output->first = kGumboNoChar;
    return true;
  }
  switch (utf8iterator_current(input)) {
    case '\t':
    case '\n':
    case '\f':
    case ' ':
    case '<':
    case '&':
    case -1:
      utf8iterator_reset(input);
      return true;
    case '#':
      return consume_numeric_ref(parser, input, &output->first);
    default:
      return consume_named_ref(parser, input, is_in_attribute, output);
  }
}
