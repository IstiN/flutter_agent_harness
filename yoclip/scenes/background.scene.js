// Full-length stage: dark base, two drifting blurred color orbs, vignette.

scene = {
  id: 'background',
  duration: 900,
  from: 0,
  timeline: { label: 'Background', color: '#26304A', lane: 'video' },
  render: function(frame) {
    var W = yoclipFormat.width;
    var H = yoclipFormat.height;
    var bg = yoclipColor('background', '#070A10');

    var d = Math.min(W, H);
    var orbR = d * 0.62;

    // Slow drift so the stage never feels static.
    var o1x = W * 0.16 + float(frame, W * 0.03, 0.011, 0);
    var o1y = H * 0.20 + float(frame, H * 0.03, 0.013, 2);
    var o2x = W * 0.84 + float(frame, W * 0.03, 0.009, 4);
    var o2y = H * 0.82 + float(frame, H * 0.03, 0.012, 1);

    return {
      type: 'stack', fit: 'expand',
      children: [
        { type: 'absolute_fill', color: bg },
        {
          type: 'container',
          width: orbR, height: orbR, borderRadius: orbR / 2,
          color: yoclipColorA('primary', 0x30),
          blur: d * 0.09,
          alignment: 'topLeft',
          offsetX: o1x - orbR / 2, offsetY: o1y - orbR / 2,
        },
        {
          type: 'container',
          width: orbR * 0.85, height: orbR * 0.85, borderRadius: orbR,
          color: yoclipColorA('accent', 0x22),
          blur: d * 0.09,
          alignment: 'topLeft',
          offsetX: o2x - orbR * 0.425, offsetY: o2y - orbR * 0.425,
        },
        {
          type: 'absolute_fill',
          child: {
            type: 'container',
            gradient: {
              type: 'radial', center: 'center', radius: 0.95,
              colors: ['#00000000', '#B304060C'],
            },
          },
        },
      ],
    };
  },
};
