// test-20ch.scd
// 20-channel speaker test:
//   - boots the server with 20 output channels
//   - enveloped pink noise SynthDef
//   - HOA (ATK) encode of a single source, autopanned spherically
//   - decoded by the IEM SimpleDecoder VST (loads the .json config itself)
//
// The IEM plugin owns the decode: it reads ExpectedInputNormalization (n3d, which
// matches ATK), applies the maxrE weighting and the loudspeaker routing internally.
// Load the .json once via the editor, then ~saveDecoderState saves a .vstpreset so
// future boots can restore it with ~vst.dec.readProgram.

s.quit;

(
~dir           = thisProcess.nowExecutingPath.dirname;
~order         = 5;                    // matches the dodekaotto decoder -> 36 HOA channels
~ambiChans     = (~order + 1).squared; // 36
~nSpeakers     = 20;
~decoderPath   = ~dir +/+ "dodekaotto - 5th-virtual-speakers.json";  // load this in the editor
~decoderVST    = "SimpleDecoder.vst3"; // IEM playback decoder (AllRADecoder.vst3 also works)
~decoderPreset = ~dir +/+ "decoders" +/+ "dodekaotto.vstpreset";     // saved plugin state

s.options.numOutputBusChannels = 24;
s.options.memSize     = 2.pow(18);
s.options.device = "ASIO : MOTU Pro Audio";
s.options.numWireBufs = 1024;

// ---- boot --------------------------------------------------------------------
s.waitForBoot({
	AtkHoa.setDefaultOrder(~order);
	~encMatrix = HoaMatrixEncoder.newDirection(0, 0, order: ~order);
	s.sync;

	~ambiBus = Bus.audio(s, ~ambiChans);   // main HOA mix bus
	s.sync;

	// enveloped pink noise, encoded + spherically autopanned in-synth
	SynthDef(\pinkAmbi, {
		var env = EnvGen.kr(
			Env.asr(\atk.kr(0.5), 1, \rel.kr(1.5), \sin),
			\gate.kr(1), doneAction: 2);
		var src = PinkNoise.ar(\amp.kr(0.2)) * env;
		var az  = LFSaw.kr(\azRate.kr(0.1)) * pi;        // continuous 360-degree spin
		var el  = SinOsc.kr(\elRate.kr(0.06)) * (pi/2);  // pole-to-pole sweep
		var b   = HoaEncodeMatrix.ar(src, ~encMatrix);
		b = HoaTumble.ar(b, el);   // elevation
		b = HoaRotate.ar(b, az);   // azimuth
		Out.ar(\out.ir(0), b);
	}).add;

	// direct (non-ambisonic) pink-noise burst to a single output channel
	SynthDef(\pinkBurst, {
		var env = EnvGen.kr(
			Env.perc(\atk.kr(0.005), \rel.kr(0.25), 1, \curve.kr(-4)),
			doneAction: 2);
		var src = PinkNoise.ar(\amp.kr(0.3)) * env;
		Out.ar(\out.ir(0), src);
	}).add;

	// IEM VST decoder: 36-ch HOA in -> EnergyVisualizer (pass-through) -> 20 loudspeaker out
	SynthDef(\vstDecoder, {
		var sig = In.ar(\in.ir(0), ~ambiChans);
		sig = VSTPlugin.ar(sig, ~ambiChans, id: \viz);   // EnergyVisualizer (analyses, passes through)
		sig = VSTPlugin.ar(sig, ~nSpeakers,  id: \dec);  // SimpleDecoder
		Out.ar(\out.ir(0), sig);
	}).add;
	s.sync;

	VSTPlugin.search(s);
	s.sync;

	~decoder = Synth(\vstDecoder, [\in, ~ambiBus, \out, 0], addAction: \addToTail);
	~vst = VSTPluginController.collect(~decoder);

	~vst.viz.open("EnergyVisualizer.vst3", editor: true, action: { |self, ok|
		if (ok) { self.editor } { "could not open EnergyVisualizer.vst3".warn };
	});

	~vst.dec.open(~decoderVST, editor: true, action: { |self, ok|
		if (ok) {
			if (File.exists(~decoderPreset)) {
				self.readProgram(~decoderPreset);
				"decoder: restored state from %".format(~decoderPreset).postln;
			} {
				self.editor;
				"decoder: in the editor, click 'Load configuration' and choose:".postln;
				("  " ++ ~decoderPath).postln;
				"then run  ~saveDecoderState.()  to persist it.".postln;
			};
		} {
			"could not open % (check VSTPlugin.search results / plugin name)".format(~decoderVST).warn;
		};
	});

	// save the plugin state (run after loading the config in the editor)
	~saveDecoderState = {
		File.mkdir(~decoderPreset.dirname);
		~vst.dec.writeProgram(~decoderPreset);
		"decoder state saved to %".format(~decoderPreset).postln;
	};

	"--- 20ch test ready: % speakers, order % (% HOA chans) ---".format(~nSpeakers, ~order, ~ambiChans).postln;
});
)

// ---- speaker check: direct bursts, one channel at a time (no ambisonics) -----
// Walks outputs 0..19 with a short pink-noise burst on each — verifies routing
// and that every speaker is alive before testing the ambisonic decode.
(
~speakerCheck = Pbind(
	\instrument, \pinkBurst,
	\out,  Pseq((0 .. 15), inf),   // one pass; use inf to loop
	\dur,  0.1,
	\atk,  0.01,
	\rel,  0.05,
	\amp,  0.1,
).play;
)

// loop it (handy while walking the room)
~speakerCheck = Pbind(
	\instrument, \pinkBurst,
	\out,  Pseq((0 .. 19), inf),
	\dur,  0.5, \rel, 0.35, \amp, 0.3,
).play;
~speakerCheck.stop;

// fire a single speaker by index
Synth(\pinkBurst, [\out, 0, \amp, 0.3]);

// ---- run (ambisonics) --------------------------------------------------------
// start the autopanning pink noise (placed before the decoder in the chain)
~src = Synth(\pinkAmbi, [\out, ~ambiBus, \amp, 0.2, \azRate, 0.1, \elRate, 0.06], ~decoder, \addBefore);

// vary the motion
~src.set(\azRate, 0.3, \elRate, 0.15);   // faster
~src.set(\azRate, 0.05, \elRate, 0.03);  // slower

// fade out / free
~src.set(\gate, 0);

// ---- decoder / visualizer plugins ------------------------------------------
~vst.dec.editor;        // decoder GUI (load the .json config here the first time)
~vst.viz.editor;        // EnergyVisualizer GUI
~saveDecoderState.();   // persist the loaded config to ~decoderPreset (.vstpreset)
~vst.dec.readProgram(~decoderPreset);   // restore it manually if needed

// metering across the 20 outputs
s.meter(~nSpeakers, 0);
