precision highp float;
varying vec2 v_texcoord;
uniform sampler2D tex;

void main() {
    vec4 pixColor = texture2D(tex, v_texcoord);
    // Warm tint - reduce blue, slightly reduce green
    pixColor.r *= 1.0;
    pixColor.g *= 0.75;
    pixColor.b *= 0.5;
    gl_FragColor = pixColor;
}
