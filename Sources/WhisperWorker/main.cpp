// Versioned, bounded local pipe protocol. Model weights live for one job;
// decoder state is fresh for each request so sources never share context.
#include "whisper.h"
#include "common-whisper.h"
#include "json.hpp"
#include <iostream>
#include <fstream>
#include <memory>
#include <vector>
using json = nlohmann::ordered_json;
static void reply(const json &j) { std::cout << j.dump() << '\n' << std::flush; }
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    auto params = whisper_context_default_params();
    std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(
        whisper_init_from_file_with_params_no_state(argv[1], params), whisper_free);
    if (!ctx) return 3;
    reply({{"version",1},{"ready",true}});
    for (;;) {
        // getline alone has an unbounded allocation on malformed input.
        std::string line; char c;
        while (std::cin.get(c) && c != '\n') { if (line.size() >= 8192) return 4; line += c; }
        if (line.empty() && !std::cin) break;
        std::string id;
        try {
            auto req = json::parse(line); id = req.at("id").get<std::string>();
            if (req.at("version") != 1 || id.size() > 64) return 4;
            auto path = req.at("path").get<std::string>();
            auto language = req.at("language").get<std::string>();
            std::ifstream file(path, std::ios::binary | std::ios::ate);
            if (!file || file.tellg() > 8*1024*1024) throw std::runtime_error("Invalid audio chunk");
            std::vector<float> pcm; std::vector<std::vector<float>> stereo;
            if (!read_audio_data(path, pcm, stereo, false) || pcm.size() > 30*16000) throw std::runtime_error("Invalid audio chunk");
            std::unique_ptr<whisper_state, decltype(&whisper_free_state)> state(whisper_init_state(ctx.get()), whisper_free_state);
            if (!state) throw std::runtime_error("Cannot allocate decoder state");
            auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            p.beam_search.beam_size = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH).beam_search.beam_size;
            p.strategy = p.beam_search.beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
            p.n_threads = 4; p.language = language.c_str(); p.translate = false;
            p.print_progress = p.print_realtime = p.print_timestamps = p.print_special = false;
            if (whisper_full_with_state(ctx.get(), state.get(), p, pcm.data(), (int)pcm.size()) != 0) throw std::runtime_error("Inference failed");
            json parts = json::array();
            for (int i=0; i<whisper_full_n_segments_from_state(state.get()); ++i)
                parts.push_back({{"from",whisper_full_get_segment_t0_from_state(state.get(),i)*10},
                    {"to",whisper_full_get_segment_t1_from_state(state.get(),i)*10},
                    {"text",whisper_full_get_segment_text_from_state(state.get(),i)}});
            auto result = json{{"version",1},{"id",id},{"segments",parts}};
            if (result.dump().size() > 1024*1024) throw std::runtime_error("Response too large");
            reply(result);
        } catch (const std::exception &e) { reply({{"version",1},{"id",id},{"error",e.what()}}); }
    }
    return 0;
}
