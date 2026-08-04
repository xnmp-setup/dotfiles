#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

const float temperature = 3500.0;

vec3 colorTemperatureToRGB(const in float kelvin) {
    mat3 coefficients = (kelvin <= 6500.0)
        ? mat3(vec3(0.0, -2902.1955373783176, -8257.7997278925690),
               vec3(0.0, 1669.5803561666639, 2575.2827530017594),
               vec3(1.0, 1.3302673723350029, 1.8993753891711275))
        : mat3(vec3(1745.0425298314172, 1216.6168361476490, -8257.7997278925690),
               vec3(-2666.3474220535695, -2173.1012343082230, 2575.2827530017594),
               vec3(0.55995389139931482, 0.70381203140554553, 1.8993753891711275));

    return mix(
        clamp(
            coefficients[0]
                / (vec3(clamp(kelvin, 1000.0, 40000.0)) + coefficients[1])
                + coefficients[2],
            0.0,
            1.0
        ),
        vec3(1.0),
        smoothstep(1000.0, 0.0, kelvin)
    );
}

void main() {
    vec4 pixel = texture(tex, v_texcoord);
    fragColor = vec4(pixel.rgb * colorTemperatureToRGB(temperature), pixel.a);
}
