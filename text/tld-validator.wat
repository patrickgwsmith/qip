(module $TLDValidator
  (memory (export "memory") 4 4)
  (global $input_ptr i32 (i32.const 0x10000))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 0x10000))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))

  ;; TLD data stored as length-prefixed strings in memory
  ;; Format: [length:1byte][tld:Nbytes]...
  ;; Starting at address 0x30000
  (global $tld_data_ptr i32 (i32.const 0x30000))
  (global $tld_data_end (mut i32) (i32.const 0x30000))  ;; Will be set after data

  ;; Check if character is ASCII whitespace
  (func $is_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))
          (i32.or
            (i32.eq (local.get $c) (i32.const 12))
            (i32.eq (local.get $c) (i32.const 13))
          )
        )
      )
    )
  )

  ;; Convert ASCII uppercase to lowercase
  (func $to_lower (param $c i32) (result i32)
    (if (result i32)
      (i32.and
        (i32.ge_u (local.get $c) (i32.const 65))
        (i32.le_u (local.get $c) (i32.const 90)))
      (then
        (i32.add (local.get $c) (i32.const 32))
      )
      (else
        (local.get $c)
      )
    )
  )

  ;; Compare TLD (case-insensitive)
  (func $compare_tld (param $tld_start i32) (param $tld_len i32) (param $data_ptr i32) (param $data_len i32) (result i32)
    (local $i i32)

    (if (i32.ne (local.get $tld_len) (local.get $data_len))
      (then (return (i32.const 0)))
    )

    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $i) (local.get $tld_len)))
        (if (i32.ne
          (call $to_lower (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $tld_start) (local.get $i)))))
          (i32.load8_u (i32.add (local.get $data_ptr) (local.get $i))))
          (then (return (i32.const 0)))
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )
    (i32.const 1)
  )

  ;; Check if TLD is valid by searching through the data
  (func $is_valid_tld (param $tld_start i32) (param $tld_len i32) (result i32)
    (local $ptr i32)
    (local $len i32)

    (local.set $ptr (global.get $tld_data_ptr))

    (block $break
      (loop $continue
        ;; Check if we've reached the end
        (br_if $break (i32.ge_u (local.get $ptr) (global.get $tld_data_end)))

        ;; Read length byte
        (local.set $len (i32.load8_u (local.get $ptr)))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 1)))

        ;; Compare this TLD
        (if (call $compare_tld (local.get $tld_start) (local.get $tld_len) (local.get $ptr) (local.get $len))
          (then (return (i32.const 1)))
        )

        ;; Move to next TLD
        (local.set $ptr (i32.add (local.get $ptr) (local.get $len)))
        (br $continue)
      )
    )

    (i32.const 0)
  )

  ;; All current TLDs (as of January 2026, from IANA) stored as length-prefixed strings
  ;; Source: https://data.iana.org/TLD/tlds-alpha-by-domain.txt (excluding XN-- internationalized domains)
  ;; 1287 TLDs, 7532 bytes total
  (data (i32.const 0x30000) "\03aaa\04aarp\03abb\06abbott\06abbvie\03abc\04able\07abogado\08abudhabi\02ac\07academy\09accenture\0aaccountant\0baccountants\03aco\05actor\02ad\03ads\05adult\02ae\03aeg\04aero\05aetna\02af\03afl\06africa\02ag\07agakhan\06agency\02ai\03aig\06airbus\08airforce\06airtel\04akdn\02al\07alibaba\06alipay\09allfinanz\08allstate\04ally\06alsace\06alstom\02am\06amazon\0famericanexpress\0eamericanfamily\04amex\05amfam\05amica\09amsterdam\09analytics\07android\06anquan\03anz\02ao\03aol\0aapartments\03app\05apple\02aq\09aquarelle\02ar\04arab\06aramco\05archi\04army\04arpa\03art\04arte\02as\04asda\04asia\0aassociates\02at\07athleta\08attorney\02au\07auction\04audi\07audible\05audio\07auspost\06author\04auto\05autos\02aw\03aws\02ax\03axa\02az\05azure\02ba\04baby\05baidu\07banamex\04band\04bank\03bar\09barcelona\0bbarclaycard\08barclays\08barefoot\08bargains\08baseball\0abasketball\07bauhaus\06bayern\02bb\03bbc\03bbt\04bbva\03bcg\03bcn\02bd\02be\05beats\06beauty\04beer\06berlin\04best\07bestbuy\03bet\02bf\02bg\02bh\06bharti\02bi\05bible\03bid\04bike\04bing\05bingo\03bio\03biz\02bj\05black\0bblackfriday\0bblockbuster\04blog\09bloomberg\04blue\02bm\03bms\03bmw\02bn\0abnpparibas\02bo\05boats\0aboehringer\04bofa\03bom\04bond\03boo\04book\07booking\05bosch\06bostik\06boston\03bot\08boutique\03box\02br\08bradesco\0bbridgestone\08broadway\06broker\07brother\08brussels\02bs\02bt\05build\08builders\08business\03buy\04buzz\02bv\02bw\02by\02bz\03bzh\02ca\03cab\04cafe\03cal\04call\0bcalvinklein\03cam\06camera\04camp\05canon\08capetown\07capital\0acapitalone\03car\07caravan\05cards\04care\06career\07careers\04cars\04casa\04case\04cash\06casino\03cat\08catering\08catholic\03cba\03cbn\04cbre\02cc\02cd\06center\03ceo\04cern\02cf\03cfa\03cfd\02cg\02ch\06chanel\07channel\07charity\05chase\04chat\05cheap\07chintai\09christmas\06chrome\06church\02ci\08cipriani\06circle\05cisco\07citadel\04citi\05citic\04city\02ck\02cl\06claims\08cleaning\05click\06clinic\08clinique\08clothing\05cloud\04club\07clubmed\02cm\02cn\02co\05coach\05codes\06coffee\07college\07cologne\03com\08commbank\09community\07company\07compare\08computer\06comsec\06condos\0cconstruction\0aconsulting\07contact\0bcontractors\07cooking\04cool\04coop\07corsica\07country\06coupon\07coupons\07courses\03cpa\02cr\06credit\0acreditcard\0bcreditunion\07cricket\05crown\03crs\06cruise\07cruises\02cu\0acuisinella\02cv\02cw\02cx\02cy\05cymru\04cyou\02cz\03dad\05dance\04data\04date\06dating\06datsun\03day\04dclk\03dds\02de\04deal\06dealer\05deals\06degree\08delivery\04dell\08deloitte\05delta\08democrat\06dental\07dentist\04desi\06design\03dev\03dhl\08diamonds\04diet\07digital\06direct\09directory\08discount\08discover\04dish\03diy\02dj\02dk\02dm\03dnp\02do\04docs\06doctor\03dog\07domains\03dot\08download\05drive\03dtv\05dubai\06dupont\06durban\04dvag\03dvr\02dz\05earth\03eat\02ec\03eco\05edeka\03edu\09education\02ee\02eg\05email\06emerck\06energy\08engineer\0bengineering\0benterprises\05epson\09equipment\02er\08ericsson\04erni\02es\03esq\06estate\02et\02eu\0aeurovision\03eus\06events\08exchange\06expert\07exposed\07express\0aextraspace\04fage\04fail\09fairwinds\05faith\06family\03fan\04fans\04farm\07farmers\07fashion\04fast\05fedex\08feedback\07ferrari\07ferrero\02fi\08fidelity\04fido\04film\05final\07finance\09financial\04fire\09firestone\08firmdale\04fish\07fishing\03fit\07fitness\02fj\02fk\06flickr\07flights\04flir\07florist\07flowers\03fly\02fm\02fo\03foo\04food\08football\04ford\05forex\07forsale\05forum\0afoundation\03fox\02fr\04free\09fresenius\03frl\07frogans\08frontier\03ftr\07fujitsu\03fun\04fund\09furniture\06futbol\03fyi\02ga\03gal\07gallery\05gallo\06gallup\04game\05games\03gap\06garden\03gay\02gb\04gbiz\02gd\03gdn\02ge\03gea\04gent\07genting\06george\02gf\02gg\04ggee\02gh\02gi\04gift\05gifts\05gives\06giving\02gl\05glass\03gle\06global\05globo\02gm\05gmail\04gmbh\03gmo\03gmx\02gn\07godaddy\04gold\09goldpoint\04golf\03goo\08goodyear\04goog\06google\03gop\03got\03gov\02gp\02gq\02gr\08grainger\08graphics\06gratis\05green\05gripe\07grocery\05group\02gs\02gt\02gu\05gucci\04guge\05guide\07guitars\04guru\02gw\02gy\04hair\07hamburg\07hangout\04haus\03hbo\04hdfc\08hdfcbank\06health\0ahealthcare\04help\08helsinki\04here\06hermes\06hiphop\09hisamitsu\07hitachi\03hiv\02hk\03hkt\02hm\02hn\06hockey\08holdings\07holiday\09homedepot\09homegoods\05homes\09homesense\05honda\05horse\08hospital\04host\07hosting\03hot\06hotels\07hotmail\05house\03how\02hr\04hsbc\02ht\02hu\06hughes\05hyatt\07hyundai\03ibm\04icbc\03ice\03icu\02id\02ie\04ieee\03ifm\05ikano\02il\02im\06imamat\04imdb\04immo\0aimmobilien\02in\03inc\0aindustries\08infiniti\04info\03ing\03ink\09institute\09insurance\06insure\03int\0dinternational\06intuit\0binvestments\02io\08ipiranga\02iq\02ir\05irish\02is\07ismaili\03ist\08istanbul\02it\04itau\03itv\06jaguar\04java\03jcb\02je\04jeep\05jetzt\07jewelry\03jio\03jll\02jm\03jmp\03jnj\02jo\04jobs\06joburg\03jot\03joy\02jp\08jpmorgan\04jprs\06juegos\07juniper\06kaufen\04kddi\02ke\0bkerryhotels\0fkerryproperties\03kfh\02kg\02kh\02ki\03kia\04kids\03kim\06kindle\07kitchen\04kiwi\02km\02kn\05koeln\07komatsu\06kosher\02kp\04kpmg\03kpn\02kr\03krd\04kred\09kuokgroup\02kw\02ky\05kyoto\02kz\02la\07lacaixa\0blamborghini\05lamer\04land\09landrover\07lanxess\07lasalle\03lat\06latino\07latrobe\03law\06lawyer\02lb\02lc\03lds\05lease\07leclerc\06lefrak\05legal\04lego\05lexus\04lgbt\02li\04lidl\04life\0dlifeinsurance\09lifestyle\08lighting\04like\05lilly\07limited\04limo\07lincoln\04link\04live\06living\02lk\03llc\03llp\04loan\05loans\06locker\05locus\03lol\06london\05lotte\05lotto\04love\03lpl\0clplfinancial\02lr\02ls\02lt\03ltd\04ltda\02lu\08lundbeck\04luxe\06luxury\02lv\02ly\02ma\06madrid\04maif\06maison\06makeup\03man\0amanagement\05mango\03map\06market\09marketing\07markets\08marriott\09marshalls\06mattel\03mba\02mc\08mckinsey\02md\02me\03med\05media\04meet\09melbourne\04meme\08memorial\03men\04menu\08merckmsd\02mg\02mh\05miami\09microsoft\03mil\04mini\04mint\03mit\0amitsubishi\02mk\02ml\03mlb\03mls\02mm\03mma\02mn\02mo\04mobi\06mobile\04moda\03moe\03moi\03mom\06monash\05money\07monster\06mormon\08mortgage\06moscow\04moto\0bmotorcycles\03mov\05movie\02mp\02mq\02mr\02ms\03msd\02mt\03mtn\03mtr\02mu\06museum\05music\02mv\02mw\02mx\02my\02mz\02na\03nab\06nagoya\04name\04navy\03nba\02nc\02ne\03nec\03net\07netbank\07netflix\07network\07neustar\03new\04news\04next\0anextdirect\05nexus\02nf\03nfl\02ng\03ngo\03nhk\02ni\04nico\04nike\05nikon\05ninja\06nissan\06nissay\02nl\02no\05nokia\06norton\03now\06nowruz\05nowtv\02np\02nr\03nra\03nrw\03ntt\02nu\03nyc\02nz\03obi\08observer\06office\07okinawa\06olayan\0bolayangroup\04ollo\02om\05omega\03one\03ong\03onl\06online\03ooo\04open\06oracle\06orange\03org\07organic\07origins\05osaka\06otsuka\03ott\03ovh\02pa\04page\09panasonic\05paris\04pars\08partners\05parts\05party\03pay\04pccw\02pe\03pet\02pf\06pfizer\02pg\02ph\08pharmacy\03phd\07philips\05phone\05photo\0bphotography\06photos\06physio\04pics\06pictet\08pictures\03pid\03pin\04ping\04pink\07pioneer\05pizza\02pk\02pl\05place\04play\0bplaystation\08plumbing\04plus\02pm\02pn\03pnc\04pohl\05poker\07politie\04porn\04post\02pr\05praxi\05press\05prime\03pro\04prod\0bproductions\04prof\0bprogressive\05promo\0aproperties\08property\0aprotection\03pru\0aprudential\02ps\02pt\03pub\02pw\03pwc\02py\02qa\04qpon\06quebec\05quest\06racing\05radio\02re\04read\0arealestate\07realtor\06realty\07recipes\03red\0bredumbrella\05rehab\05reise\06reisen\04reit\08reliance\03ren\04rent\07rentals\06repair\06report\0arepublican\04rest\0arestaurant\06review\07reviews\07rexroth\04rich\09richardli\05ricoh\03ril\03rio\03rip\02ro\05rocks\05rodeo\06rogers\04room\02rs\04rsvp\02ru\05rugby\04ruhr\03run\02rw\03rwe\06ryukyu\02sa\08saarland\04safe\06safety\06sakura\04sale\05salon\08samsclub\07samsung\07sandvik\0fsandvikcoromant\06sanofi\03sap\04sarl\03sas\04save\04saxo\02sb\03sbi\03sbs\02sc\03scb\0aschaeffler\07schmidt\0cscholarships\06school\06schule\07schwarz\07science\04scot\02sd\02se\06search\04seat\06secure\08security\04seek\06select\05sener\08services\05seven\03sew\03sex\04sexy\03sfr\02sg\02sh\09shangrila\05sharp\05shell\04shia\07shiksha\05shoes\04shop\08shopping\06shouji\04show\02si\04silk\04sina\07singles\04site\02sj\02sk\03ski\04skin\03sky\05skype\02sl\05sling\02sm\05smart\05smile\02sn\04sncf\02so\06soccer\06social\08softbank\08software\04sohu\05solar\09solutions\04song\04sony\03soy\03spa\05space\05sport\04spot\02sr\03srl\02ss\02st\05stada\07staples\04star\09statebank\09statefarm\03stc\08stcgroup\09stockholm\07storage\05store\06stream\06studio\05study\05style\02su\05sucks\08supplies\06supply\07support\04surf\07surgery\06suzuki\02sv\06swatch\05swiss\02sx\02sy\06sydney\07systems\02sz\03tab\06taipei\04talk\06taobao\06target\0atatamotors\05tatar\06tattoo\03tax\04taxi\02tc\03tci\02td\03tdk\04team\04tech\0atechnology\03tel\07temasek\06tennis\04teva\02tf\02tg\02th\03thd\07theater\07theatre\04tiaa\07tickets\06tienda\04tips\05tires\05tirol\02tj\06tjmaxx\03tjx\02tk\06tkmaxx\02tl\02tm\05tmall\02tn\02to\05today\05tokyo\05tools\03top\05toray\07toshiba\05total\05tours\04town\06toyota\04toys\02tr\05trade\07trading\08training\06travel\09travelers\12travelersinsurance\05trust\03trv\02tt\04tube\03tui\05tunes\05tushu\02tv\03tvs\02tw\02tz\02ua\05ubank\03ubs\02ug\02uk\06unicom\0auniversity\03uno\03uol\03ups\02us\02uy\02uz\02va\09vacations\04vana\08vanguard\02vc\02ve\05vegas\08ventures\08verisign\0cversicherung\03vet\02vg\02vi\06viajes\05video\03vig\06viking\06villas\03vin\03vip\06virgin\04visa\06vision\04viva\04vivo\0avlaanderen\02vn\05vodka\05volvo\04vote\06voting\04voto\06voyage\02vu\05wales\07walmart\06walter\04wang\07wanggou\05watch\07watches\07weather\0eweatherchannel\06webcam\05weber\07website\03wed\07wedding\05weibo\04weir\02wf\07whoswho\04wien\04wiki\0bwilliamhill\03win\07windows\04wine\07winners\03wme\0dwolterskluwer\08woodside\04work\05works\05world\03wow\02ws\03wtc\03wtf\04xbox\05xerox\06xihuan\03xin\03xxx\03xyz\06yachts\05yahoo\07yamaxun\06yandex\02ye\09yodobashi\04yoga\08yokohama\03you\07youtube\02yt\03yun\02za\06zappos\04zara\04zero\03zip\02zm\04zone\07zuerich\02zw")

  (func $init
    ;; End address: start (0x30000) + data length (7532 bytes) = 0x31d6c
    (global.set $tld_data_end (i32.const 0x31d6c))
  )

  ;; Returns: length of valid TLD, or 0 if invalid
  (func $render_size (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $i i32)
    (local $last_dot i32)
    (local $tld_start i32)
    (local $tld_len i32)
    (local $current_char i32)

    ;; Initialize TLD data end pointer
    (call $init)

    ;; Empty input is invalid
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Trim leading whitespace
    (local.set $start (i32.const 0))
    (block $break_leading
      (loop $continue_leading
        (br_if $break_leading (i32.ge_u (local.get $start) (local.get $input_size)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
        (br_if $break_leading (i32.eqz (call $is_whitespace (local.get $current_char))))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $continue_leading)
      )
    )

    ;; Trim trailing whitespace
    (local.set $end (local.get $input_size))
    (block $break_trailing
      (loop $continue_trailing
        (br_if $break_trailing (i32.le_u (local.get $end) (local.get $start)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
        (br_if $break_trailing (i32.eqz (call $is_whitespace (local.get $current_char))))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $continue_trailing)
      )
    )

    ;; If empty after trimming, invalid
    (if (i32.ge_u (local.get $start) (local.get $end))
      (then (return (i32.const 0)))
    )

    ;; Find the last dot
    (local.set $last_dot (i32.const -1))
    (local.set $i (local.get $start))
    (block $break_find_dot
      (loop $continue_find_dot
        (br_if $break_find_dot (i32.ge_u (local.get $i) (local.get $end)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
        (if (i32.eq (local.get $current_char) (i32.const 46))
          (then (local.set $last_dot (local.get $i)))
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue_find_dot)
      )
    )

    ;; No dot found, invalid domain
    (if (i32.eq (local.get $last_dot) (i32.const -1))
      (then (return (i32.const 0)))
    )

    ;; TLD starts after the last dot
    (local.set $tld_start (i32.add (local.get $last_dot) (i32.const 1)))
    (local.set $tld_len (i32.sub (local.get $end) (local.get $tld_start)))

    ;; TLD must be at least 2 characters
    (if (i32.lt_u (local.get $tld_len) (i32.const 2))
      (then (return (i32.const 0)))
    )

    ;; Check if TLD is valid
    (if (i32.eqz (call $is_valid_tld (local.get $tld_start) (local.get $tld_len)))
      (then (return (i32.const 0)))
    )

    ;; Copy TLD to output (lowercase)
    (local.set $i (i32.const 0))
    (block $break_copy
      (loop $copy
        (br_if $break_copy (i32.ge_u (local.get $i) (local.get $tld_len)))
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $i))
          (call $to_lower (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $tld_start) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $copy)
      )
    )

    (local.get $tld_len)
  )
  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)