<title>Empirical agents with hard constraints, strict isolation & trusty protocols</title>

# Empirical agents with hard constraints, strict isolation & trusty protocols

Agentic coding now allows every language to be treated as a scripting language. Whether you write JavaScript, Lua, or Rust, the same prompt can create a working program in any of the popular LLMs.

We have been given a gearbox, where first gear writes a little regex or bash script, and top gear thunders at full throttle tens of thousands of lines of assembly code.

But what is the blast radius of one of those lines? Assembly can run syscalls, talk to hardware, and hose your system. Is this the right abstraction layer for the coming wave of security exploits that AI also brings? Casey Muratori encourages us to at least be able to read assembly, which I support, but is this what I want to default to for my code review? Will I rely on static analysis tools to detect any “bad” assembly instructions or any paths of logic that are likely problematic? I’m trying to marry a probabilistic generator (the coding agent) with another probabilistic filter (humans, evolving linter rules).

We saw this a year ago with React2Shell https://www.cisecurity.org/advisory/a-vulnerability-in-react-server-component-rsc-could-allow-for-remote-code-execution_2025-111 with “unsafe deserialization of RSC “Flight” protocol payloads, enabling an attacker to send a crafted request that triggers execution of code on the server.” https://www.offsec.com/blog/cve-2025-55182/ “The vulnerability received a maximum CVSS score of 10.0”

To me this underscored a few things. First, we should stick to venerable protocols that have had decades to mature and receive intense security study. RSC was added to one of the most popular software libraries ever made and crossed the stack from client input to network communication to server runtime in ways that made bugs particularly high stakes.

Second, we should limit the blast radius of code, especially when handling untrusted input. Our web servers have been dealing with things like SQL injection for years, and iMessage employs a sandboxed parser and validator called BlastDoor. Web browsers run each tab in its own sandbox — why don’t all apps and servers work like this?

Third, the issues in the RSC Flight protocol were quickly fixed, but the potential still lay there like Godzilla hibernating waiting for the next sequel. Could we accidentally introduce a similar vulnerability by vibe coding React? What about installing the wrong NPM package? I’m skeptical that delaying updating dependencies is a reliable solution to supply chain attacks. It’s like waiting for the person in front of you to step on the Titanic lifeboat to see if it sinks or not. It’s a strategy for survival forged in dangerous waters and I want solid land.

Simon Willison coined the term The Lethal Trifecta https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/ where untrusted content mixed with private data and external communication were a poisonous cocktail. By vibe coding and skipping code review are we potentially performing the Lethal Trifecta on ourselves? How can we trust the AI-produced and third-party-made code and weave in private data deploy that securely to the internet to communicate with customers and systems?

What if we made something that was guaranteed to have no “bad” instructions? What if our code couldn’t hose the system even if it tried? What if the program always worked the same way no matter whose machine it ran on, whether GitHub was down, or Cargo or NPM were hacked?

Fortunately, it already exists and it ships in every browser and has runtimes for every popular platform: it’s WebAssembly.

So far in its decade-long life, WebAssembly has had gradual adoption. Figma uses it heavily for its data model and rendering. Zoom uses it for their custom video codec in web browsers: https://www.zoom.com/en/blog/how-zooms-video-sdk-stacks-up/ Firefox uses it to isolate third party libraries by compiling C/C++ to WebAssembly and then converting that back to memory-safe C https://firefox-source-docs.mozilla.org/rlbox/index.html 

But most applications don’t primarily use WebAssembly. This article will explore this but by not rewriting absolutely everything in WebAssembly. We’ll strategically identify the deterministic parts of our logic that can be extracted out into wasm modules. I like to embed these into existing hosts in standard vanilla stacks that speak conventional protocols with battle-tested networking and file system code.

One mental model I like to use for WebAssembly is as Turing-Complete JSON. Why send inert data when you can send living programs? Take a list of 319 search results for booking a hotel. If you send the entire dataset and need to tweak one sub-filter or one sort parameter, why not send the data as a WebAssembly module that makes levers available to tweak the data? That way you avoid the latency required for minor changes: you’ve transported a mini-computer over the wire that can run in the browser, on a mobile phone, on a server, or in a desktop application.

WebAssembly is like a virtual computer with 3 main ingredients: global variables that hold state from run to run, functions that contain instructions that work the same on every CPU including SIMD, and a block of memory that you can access like RAM.

From these 3 ingredients you can implement any typical computational problem. I often like to think that for a given input-to-output problem, such as encoding bytes into base 64, there exists an ideal wasm solution that uses the optimal number of bytes. It’s then your task to find that optimal wasm. Or your agent’s.

LLMs and WebAssembly are complementary forces. WebAssembly is deterministic while LLMs are non-deterministic. One is completely predictable, the other is probabilistic. One is self-contained and portable to pretty much every platform, the other requires a huge model to function.

Here are the steps I’d follow for making a WebAssembly module:

1. Break your problem down into input and output. What format do you want to receive? What format makes sense to produce?
2. Split that into smaller pieces. Are there intermediate formats that make sense as a lingua-franca for your problem space? For example, I’ve been using uncompressed KTX2 for images. It’s like a modern version of BMP. Then the WebP decoder can output KTX2 and the PNG encoder can take KTX2 as its input. You want to identify the reserve currency for your domain, like how the “US dollar” is most widely used for worldwide trade.
3. Test each step. Provide known inputs and outputs that you expect to work. If you are encoding base64, provide values that you are certain are accurate like `hello` becoming `aGVsbG8=`. If making a Markdown to HTML converter, write `# Title` becomes `<h1>Title</h1>` by hand. You can write these tests first or as you go.
4. Compare your output against existing implementations in browsers, with existing libraries, and reference implementations. Give it the exact same input and see if it produces the exact same output. Copy extensive test suites if they exist with lists of edge cases. This is how I made a Unicode 17.0.0 lowercase converter — I compared against Go’s cases.Lower and Elixir’s String.downcase/2 simply by telling the agent to make some throw-away boilerplate.

You gain confidence with these individual pieces and test each one alone, and then wire them into a sequence and test as a whole. This is the biggest lesson I learned when exploring functional programming: it’s about pure functions that compose together well, and separating side-effects from the main logic.

For me it’s important that the tools for testing are available to both me and the agent. I use a Makefile so I can just run `make test` in my shell and so can an agent. The Makefile format is excellent because it is a declarative list of tasks and it is boring so agents find them trivial to write. I don’t bother with skills or any of these integrations with the agents because that’s the only avenue to run things. I want my tools to be local and remain accessible to me.

WebAssembly has an airlock between itself and the outside world. I prefer to make that airlock very constrained, where my WebAssembly imports nothing from that world. This means no WASI, which is a POSIX-like API that gives access to the file system, network, and clock. All it does it receive input and is expected to produce some output.

I think of my WebAssembly module like a gambler at a casino who can’t see any daylight and has no idea what time of day it is. This isolation unlocks a property called determinism that is surprisingly useful. This constrained input and deterministic output sounds a lot like a React component.

I’ve been spending the last nine months developing a new component layer called QIP https://qip.dev/. The consensus in the industry over the same period is seemingly “the code doesn’t matter”. I think the shape of systems and the protocols between them do matter. We should be very considerate of the interface that something speaks, because that is what tends to last. The implementation can change but its interface should be stable. I’ll go into more about the importance of protocols later.

You may ask: why do we need a new component system, why not just use React? React in my experience is slow. There are two bottlenecks: rendering React components and the DOM. React’s diffing system allows a component to declare what a UI should look like given the current state. Simple. But hooks like useEffect and useMemo break the simplicity of this model in my experience. The React Compiler attempts to make them disappear from your source code. But they trade-off extra memory usage by adding more caches.

React is a cache (the component element tree) attempting to speed up another cache (the DOM) that fronts other caches (the layout tree and paint tree). Browsers attempt to render as much stuff on the GPU as they can. Why don’t we just bypass the middlemen and push UI pixels?

So this is the approach I’ve taken with QIP, which is an API contract that WebAssembly modules adapt. On the outside are bindings to Canvas’s putImageData() to replace the entire image frame for any UI change. On the inside of the WebAssembly is a function producing the frame buffer. It’s really that naive. I believe in naivety because that is what React taught, what if `ui = f(state)`. QIP takes it another step further, which is possible because we take out middle layers of the UI such as the DOM. We can then focus on making our `f(state)` render fast. We have a head-start by choosing WebAssembly. And then we can use agents to squeeze the performance out.

I’ve readjusted my priors. Did you know that using `.innerHTML = ` to replace an HTML element can take a millisecond? We can use the same “naive” trick rendering SVGs, such as for the chart at https://qip.dev/chart-openai-anthropic-arr (switch the radios between the bitmap KTX2 and vector SVG and you’ll find the SVG renders in under a millisecond). This is the kind of reset that removing older layers can achieve.

The overhead of the DOM adds up. A single <div> takes up 11 bytes as HTML: `<div></div>` then expands into over ten times as a DOM node in the running browser. Then when that goes into the layout tree it takes roughly 1 kilobyte. That’s a hundredfold increase!

These are the sorts of things agents are amazing at researching. You can ask its innate understanding baked into the LLM. You can then ask it to verify by spelunking in the Blink and WebKit source code. You can then ask it to run an experiment and measure something real.

There’s a spectrum I’ve found that looks like this.
Innate model -> External research -> Empirical experiment

As the LLMs get more capable you can trust its innate model more. But you ought not take its word, and I think this will hold even as models get more knowledgeable. You simply can’t know everything because it would require doing everything. So you ask the LLM to step outside and trawl through raw data. For me, this is often a source file or article or book.

There’s a saying in Formula 1 that the stopwatch never lies. An F1 team can have the most advanced engine or most sophisticated aerodynamics or most experienced driver, but all anyone cares about is “how fast was the lap?” because that determines who wins. Every F1 race is a live experiment to see which driver/car combination works best on a track. The weather conditions or available tyres or driver health may affect what happens, but in the end it’s all about what the stopwatch says.

We can use this same approach with agents. What can I measure objectively? Add traces to your implementation and benchmark each part. That will indicate where it’s slow. Tally up how much memory you use. This will affect not just space but speed too, as more memory will mean more swapping of the CPU’s caches.

This sort of thing was a chore before coding agents but now you can just ask. The agent will arm itself with a pencil, adding in the traces it needs, and a stopwatch and report back the speed. As you make changes keep the stopwatch handy. Is it faster? Did you accidentally make it way slower? The agent can iteratively measure time and memory and try to reduce these things and then measure itself. The scientific method has yielded us so much progress. Make your agents empirical.

And the best way to embrace empiricism is to treat your software like a black box. I’ve been reading The Unaccountability Machine and the author Dan Davies talks about when you have a big system the people in charge find it so complex they are forced to treat it like a black box. For the purposes of testing and validation, not knowing how something works (or could work) helps stay objective.

A QIP component is a black box: it exposes input & output buffers, and a render function to turn one into the other. That’s pretty much it. This allows you to more easily unit test it, or rewrite it, or split in into two.

Another book I’ve read recently is Inside the Box. Does this sound familiar like how AI adoption has proceeded in many companies? “The irony is that total freedom can be paralyzing, and unlimited resources don't necessarily lead to the biggest breakthroughs.” The book’s message resonated strongly with me: ”David Epstein argues that all of us—individuals, businesses, institutions, even societies—can benefit from narrowing our options. He dives into the science and practice of constraints, exploring exactly when and how guardrails can be beneficial, whether we're working with limited resources or using self-imposed boundaries to tap unexpected wells of focus and innovation.” Sounds like WebAssembly and QIP, no?

I find agents really fantastic at research. I can discover nuances about problem spaces or formats or domains. It can study papers and articles and existing implementations of solutions. It can gather test cases and edge cases and make sure we have considered them. I often use the ChatGPT app for research because I know it is constrained and cannot write any code. It takes me out of the solution mode that I am often in when using a coding agent.

Another approach I’ve discovered for testing is making oracles. These are test cases or doubles that implement the rules for what say a valid base64 encoder should abide by. If we have this input we expect this output. This input must error. By implementing these in WebAssembly we get the ability to make these oracles into fuzzers, programs that run for a long time with a wide range of inputs and observations on entirety or subset of the output.

So we have one self-contained WebAssembly oracle that is checked against another self-contained WebAssembly implementation. The first might be written in C. The second might be written in Zig. And then we can write another implementation in Rust and see that it also conforms. This is another approach for photocopying a known rock-solid implementation into a bespoke self-contained implementation. Or for quickly porting between languages. The contract for correctness is completely portable.

Here’s how I approached making a CommonMark-compliant Markdown to HTML WebAssembly QIP component:
1. I got my coding agent to read the source https://github.com/commonmark/commonmark-spec/blob/master/spec.txt specification
2. I got the agent to create an oracle based on the spec. There’s a handy list of hundreds of before/after examples at https://spec.commonmark.org/0.31.2/spec.json that it can base this oracle on.
3. I then let the agent implement in Zig as I know its enums will be useful for the inner types that a Markdown parser will need.
4. As it goes it can check if the implementation complies with our oracle spec.
5. Once it’s all working I then benchmark and study the code for the patterns it has made. I suggest paths that may work, and I research similar problem areas to fill the context window with useful similar examples.
6. I then do passes to reduce the wasm module size. Again I make suggestions, looking through the code for anything that feels superfluous or heavy.
7. I get the agent to compare against existing implementations which it downloads and benchmarks against. This gives me (and the LLM) objective data to base more optimization passes on. It also provides a ceiling of performance that I know is definitely possible.
8. I then get it to make a fork and add https://github.github.com/gfm/ GitHub Flavored Markdown extensions such as tables and task list items. Curiously, this is based on an older version of the CommonMark Spec so minor differences are found with my later CommonMark implementation.

When optimizing, the agent must continually time everything, so alterations must have observed evidence that it did actually make things faster. I find it often falls into the same traps as humans, where it assumes an approach will always be faster, or is afraid of dogma that doing something “naively” is going to slow things down substantially. All of these opinions, both baked into the model and into my mind, are stripped away as it can prove what is actually faster.

If I find it is caching I suggest to rip that stuff out. A lot of the code out there that it trained on in its corpus is prematurely optimized with overuse of caches. These “save it for later” approaches make a programmer feel like they are going to make things faster but they often use more memory for calculations a CPU can chew through in microseconds.

I made a WebAssembly debugger that steps through executing the wasm instruction-by-instruction. Because the debugger is a TUI it can be run by not just humans but by coding agents too. This has allowed further optimizations to be squeezed out of my Markdown to HTML wasm where the agent notices bottlenecks or expensive loops or unnecessary reads & writes to memory. Like riding a horse, it can race through much faster than I could unaided, while I get to steer it in the general direction.

WebAssembly is obviously not as low level as actual assembly, but has been designed to map closely to machine code. So generally I expect use of branches affecting a branch predictor, and memory layout fitting into CPU cache lines to be all relevant. You can align with the machine without having unsafe access to the raw machine.

Fungible reference implementations. Another technique I’ve found great is starting a project in a language you like. QIP’s CLI was written in Go because it has fantastic cross-platform support, allowing me to build for Mac/Linux/Windows, and has an incredible standard library with file-system and networking capabilities built-in. The only dependency I needed for the QIP CLI was wazero, which is a WebAssembly runtime. Everything else used the batteries included with Go or was generated by a coding agent. This allowed me to create a web router, commands to run and benchmark and test components.

In benchmarking various QIP components I made I found that Node.js consistently ran WebAssembly faster than wazero. V8 has had millions of dollars invested in it as the beating heart of Chrome and so it means Node.js is also fast. So it was time for a port.

It took much less than a day to recreate QIP’s CLI in Node.js. The dependencies stayed small and things got faster. I even used the opportunity to prune features I didn’t want. The first CLI had accumulated various ideas that I now had the time to see more clearly, of which parts were worth having and which weren’t. So I just ported the features I really wanted just by telling the agent a list.

Rewrites and ports are really cheap now. The original code can be a Turing-complete spec. Does this work the same way? Just run both and observe that their behavior exactly matches.

Markdown “specs” don’t make any sense to me. To me Markdown is just documentation, ideally easily consumable by both agents and humans. You can put charts in there and ASCII diagrams. But don’t pretend it’s a substitute for code.

I suggest making a prototype and then iterating on that, refining the APIs and internal stateful models. And then port a pruned version of that prototype to a brand new implementation. Establish the functionality and origin story you think you want in the first prototype, and then make the reboot. What stays canon is up to you.

The other contender for WebAssembly runtime speed is Wasmtime, which is like the Chromium of wasm. This speedy library has a crate so that made the natural second port of QIP’s CLI to be in Rust. Again this took a couple of hours. This time the featureset remained the same as the Node.js version. It’s then up to me to weigh up the trade-offs between Rust (ahead-of-time compiled self-contained executable) vs Node.js (interpreted just-in-time compiled script). These trade-offs might be technical or they might be things like npx’s ease of installation.

I now intend to recreate the original Go version again based on the Node.js version. Or throw it away, I’m not too precious about it. The most valuable things to me is the latest shipped code and the documentation and marketing material. I always liked treating code as deletable because programmers being so precious about it often led to over-engineer abstractions that they tied their self-worth to. That’s not helpful.

But neither is treating the code as completely worthless. A lot of the talk about “software factories” has me wondering if people are really creating “software treatment plants”. You pump messy requirements and tokens in and hope you get safe-to-drink software out the other end. That framing of low-value code doesn’t inspire me because it risks undervaluing your users. You should respect your users by making things with some care in them.

I like sitting on the factory floor and surrounding myself with parts and iterating until something works for me. To have good taste you have to taste what you make. I wouldn’t want to eat at a restaurant where the chef dislikes eating the food.

I like formats like HTML, SVG, RSS since they are established and usually just work. I’m also exploring old-school formats that were popular in early Unix and web days like CSV, TAR, multipart/form-data, multipart/mixed. These are designed to be parsed efficiently, so we can use less memory and lean on the experience of many years of accumulated knowledge. Also because they are old, agents know them like the back of their virtual hand.

So when making a component my first task is to find the best format for my input or output. I assume someone made one in the 80s, and then someone probably made another in the 90s, and in the 2010s. The earlier formats will usually be lighter and able to be processed with fewer resources. The newer ones will have more features like HDR or wide gamut or transparency or types or compression dictionaries trained on internet formats. Yet often fewer moving parts is better.

This is because our components’ job is to turn one input into one output. The more levers available in the output, the more decisions we have to make: do we use them all, do we restrain ourselves, which levers do we pull? The more variation in the input, the more state we have to manage internally. The more we have to test for compatibility, the more edge cases there are, the more automated testing and fuzzing we’ll have to do. The less confident we will likely be with our component.

Postel’s law of robustness advocates “be conservative in what you send, be liberal in what you accept”. This holds in a world of LLM-generated code and agents being deployed to the internet to perform useful tasks. Our agents should be conservative in what they send out into the rest of the world (this is part of the goals of alignment). But we also want to make things that are compatible and don’t fall over, or worse, have their internal state corrupted easily.

So whether you make WebAssembly or vibe code another language, hold this principle in mind. Outline the smallest piece you can get away with. Make that piece out of the most robust, and perhaps even boring, material you can find.

Another helpful concept is the idea of entropy or of innate complexity. I want only the entropy in my code that is necessary to produce the output. The entropy of the input and the entropy of the output should give an idea of the entropy or complexity of my function code in-between. A pure function of boolean -> boolean has only 4 possible implementations (always true, always false, return the argument, negate the argument). Imagine the complexity of a function that adds two numbers. Then imagine the complexity of a function that counts the number of words in a string, that converts an integer like `101` into in English like `one-hundred-and-one`, or that converts Markdown to HTML. The more you go up the scale, the more possible pathways there are, and often the many more edge cases you are going to have to tackle and test.

I want to reduce the number of possible failure modes. List what the potential failure modes are in the subsystem you are working on and see which ones you care about and which ones, through rearchitecting, you can outright dismiss. The I/O and scheduling parts of your system often have the most difficult failure modes to consider, which is why I try to keep those areas well structured as I’ll talk about shortly.

In my QIP components I want to whittle down the amount of state needed to make its output. This is where creating a duplicate with improvements and then comparing to see if anything has regressed is really valuable. The constraint of a pure function that can be extracted and duplicated lets you make comparisons trivially since the output for a given input should remain exactly the same (determinism), allowing you to experiment by pruning state and conditionals and flattening logic.

Ideally you come to agents with a mental model of the failure modes and state and required complexity of your problem in mind. LLMs can help you study these more in-depth but I think new developers should still learn from existing books and articles. A coherent mental map helps you steer the direction of your next prompt.

Think about the actual I/O in your system like the network and file system. These are the actual bottlenecks of your system. This is why technologies like Node.js were a revelation because they decoupled the network and file I/O (via an event loop managed in C++) from the business logic in JavaScript. The extra concurrency allowed more I/O operations such as more HTTP requests per second.

We should still be mindful of where those I/O boundaries are. Just because a coding agent can produce 10K lines of spaghetti that works doesn’t mean we should accept spaghetti as the norm. I’m not worried about code syntax here, I’m concerned about where input enters you system, where is gets persisted (perhaps durably to a database), and where things leave and talk to outside systems. This is the interface of our software system. We should think of it like a contract.

If a user signs up for an account and clicks around and adds their data and invites their colleagues, then this is the sort of things that should happen: they receive some emails and so do their colleagues, and their session is secure, and their data is remembered for the next time they sign in, and the key buttons they clicked last week stays roughly in the same location. That’s what the user signed up for and expects to hold as part of their subscription: that’s the contract.

I like to think of the user’s contract as being in the language of ARIA: these are the landmarks they expect to find like navigation and forms, and then these are the familiar elements that have known accessible roles like buttons, links, and textboxes. If we use the stable protocol of ARIA in our E2E tests then we gain stability in our UX contract.

Also part of that contract should be a list of nots: their data stays private and doesn’t accidentally leak or get hacked. The button doesn’t move around every week as you keep shipping continuously. You don’t accidentally email someone that was never requested. Everyone’s session remains secure and isolated from one another. We have to remain responsible for the systems we make and deploy.

This is why I believe hard constraints are necessary when agentic coding. The business logic gets made in pieces that are easily examined, easily reviewed, easily replaced, and easily audited. We stick these together into pipelines that we know cannot leak: no network or file I/O happens in-between. This makes things easier to test as we can inspect at any part of the pipeline. The pipeline being made out of deterministic pieces makes the whole pipeline deterministic meaning it won’t magically behave differently depending on the angle of the sun or the uptime of GitHub.

Only at the edges of our system do we talk to actual users or the potentially perilous world. And at these edges we are careful with what we install. We stick to venerable, established protocols that have stood the test of time. We use libraries or frameworks that have a strong reputation and have been scrutinised to build our trust. This is where I think certain classes of open source has a strong future: shared, audited, essential building blocks.

We can be experimental in our iron fortress. We shouldn’t confuse the two. The vibes should be different at the edges and at the center. We should also be strict about what data we persist, as this can get us into knots when making future features or ensuring things are secure. Operations like merging two database columns into one is a lot easier with LLMs. But remodeling the schema remains high-risk and not something to skip review on.

Tony Stark in the Iron Man movies didn’t just mindlessly ask Jarvis to produce a widget. He was involved in the process and surrounded himself with novel tools and ran experiments and wore what he made.

Recently I’ve made more tools: a native browser in Rust and Objective-C that lets you switch between the Chromium and WebKit engines, which is really great for manual testing.

[I’ve made a shell](https://crates.io/crates/lynn) that can talk to agents and make them collaborate. Your default prompt is a standard bash-like shell. You can then throw queries to Claude by writing `opus? how big is our commonmark wasm when gzipped?` that run in its readonly sandbox and get another model to implement things like `sol! show me an example of running qip-interpret-memory-thermal-ktx2 on commonmark?` that run with your full user permissions. You can bounce between the different coding agents in one single session. I can even go to multiple models with questions like `opus/sol? Is must_reject_with the most obvious API? What alternatives can you think of?`

I’ve been exploring a lot of systems programming, with the tighter constraints that making databases, aeroplanes, or infrastructure requires. Agents can be forced to follow stricter rules than we’d impose on ourselves. Tiger Style https://tigerstyle.dev/ introduced me to the idea of static allocation being viable for startups. QIP components adopts static allocation with fixed-sized buffers required for input and output. When making a component you must decide whether 16 KB or 600 MB is needed. Through testing I often find an ideal upper bound and set that to the value. Because operating systems only themselves allocate memory pages as they are read/written, a component that asks for 100 MB won’t typically use 100 MB.

A QIP component can be used again and again so the memory that is allocated remains reused for its whole lifetime. Since WebAssembly 1.0 only has a single thread we can be sure that we have exclusive access to the memory: nothing can touch it behind its back. This is similar to the property of immutability in functional programming, but we aren’t limited by things in the component actually being immutable. It can make any mutable array or efficient data structure it needs. Its only job is to turn the input buffer into the output buffer. In this way it’s like a pure function, but the guts are efficient imperative code. It’s up to us where to draw the boundary of how wide or narrow that function is. The constraint of a single thread running in isolation unlocks safety and fast performance.

And this is why I feel confident to nerd snipe a coding agent with “make a function that turns Markdown into HTML written in Zig (or C)” because the worst it can do is output ill-formed data. It can’t insert a line that allows remote code execution. My job is to draw the boundary, decide the input and output, guide the agent, and test the heck out of it.

NASA’s Power of 10 Rules https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code also encourage liberal use of assertions and enforcing loops with fixed upper bounds. https://youtu.be/GRJtYwneG2Q

I’ve been adding static analysis to my QIP components where I check for upper limits on loops so I know for certain they cannot become infinite loops. I can prohibit any WebAssembly instruction that traps, I can prevent memory from increasing by enforcing a maximum on memory and banning `(memory.grow)` that adds another page. I can even reject unchecked patterns of divide-by-zero by inspecting the WebAssembly instructions. Like the LISP people are fond of saying, code is data. As you can probably imagine, I have made QIP components that themselves take WebAssembly as input!

I encourage everyone to watch Richard Hipp, the creators of SQLite, talk about how he tests and manages the hugely popular database. https://www.youtube.com/watch?v=V_qzqY1bb7I

I’ve made a file-based router that is built around QIP, with each file type converted into an HTTP response via a pipeline of WebAssembly components all strung together. You can do middleware-like transforms to dynamically insert elements site-wide or runs checks by having components working on the web archive application/warc format that is essentially a list of multiple requests to responses. This is what powers the QIP website: https://qip.dev/

I’m making a Mac app code-named Tideland to run and one day create QIP components, one step further in fulfilling my cross-platform dreams. I’m considering a “Forkware” business model where the app will be free to anyone and those who want to extend it with their own features can pay to get access to the source code. A few years ago it was a dream to make an online course and I’m having to adjust and experiment to find what developers find valuable to buy today.

So these are areas of interest where by educating myself I can write faster, more reliable code than I did by hand five years ago, while still being accelerated by agents. My love of learning software fundamentals has not disappeared, and is in fact deepening.

Because WebAssembly Core is platform-agnostic I can place a QIP component into any existing mainstream stack, from React, to Swift, to Java, to Rust. The vibes are sandboxed with strict isolation, built within hard constraints, and talk trusty protocols.

I was never taken by cryptocurrency but this new wave of AI shows enormous promise to me. With WebAssembly we can mine actual utility. You consume tokens, you and your agent spend time researching and testing and verifying and experimenting and optimizing, and you produce a small wasm that is useful and can be run again and again to produce value for everyone. Producing meaningful value is why I got into making software.
