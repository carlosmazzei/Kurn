# Kurn: plano para 80% de cobertura mínima

## Meta e regras

- **Meta: 80% de cobertura de linhas sobre o código em escopo**, exigida no CI
  pelo job `coverage-gate` (`Tools/coverage_gate.py`).
- **Escopo** (`Tools/coverage_scope.json`): a lógica do app (`Kurn/`, sem
  `Views/`, `ContentView.swift`, `DebugSupport/` e `AppIntents/`) mais os
  fontes do KurnCore. Os corpos de view SwiftUI ficam fora, porque são
  exercitados pelos fluxos de `KurnUITests`, e não por esta métrica. Pela mesma
  regra, também fica fora todo **adapter**: arquivo que só embrulha uma API
  que exige hardware, modelo baixado, Metal/ANE ou entitlement. Um adapter
  só entra em `exclude` quando toda a decisão que ele tomava já está num tipo
  testado, e cada entrada traz a sua justificativa.
- **Gate de patch:** as linhas executáveis em escopo que um PR adiciona
  precisam estar ≥ 80% cobertas, desde já.
- **Piso (catraca):** o total em escopo e cada camada não podem cair mais de
  0,5pp abaixo de `Tools/coverage_floor.json`. O PR que sobe a cobertura roda
  `coverage_gate.py --write-floor` e commita o piso novo. O piso nunca desce.
- O Codecov continua informativo (badge, comentário, componentes). O gate é
  nosso, então uma queda do Codecov não bloqueia merge.
- Sem testes que dependam de rede, modelo baixado ou microfone. Seams vêm antes
  dos testes, e nunca se usa `#if DEBUG` dentro da lógica (mesma regra do plano anterior).

## Ponto de partida (medido em 01/10/2026, PR #240)

O primeiro run do `coverage-gate` (união unit + UI + KurnCore, só o escopo):
**69,0% de 22 025 linhas em 241 arquivos.** Esses valores viraram o piso inicial
em `Tools/coverage_floor.json`.

| Camada | Linhas | Cobertura | Meta |
|---|---:|---:|---:|
| `Packages/KurnCore` | 1 673 | 54,0% | ≥ 85% (Fase 1) |
| `Kurn/Services` | 10 319 | 62,8% | ≥ 80% (Fase 3) |
| `Kurn/Application` | 1 286 | 63,1% | ≥ 80% (Fase 4) |
| `Kurn/ViewModels` | 1 803 | 67,5% | ≥ 80% (Fase 4) |
| `Kurn/Infrastructure` | 3 741 | 80,3% | ≥ 85% (Fase 5) |
| `Kurn/Models` | 1 023 | 86,5% | manter |
| `Kurn/Providers` | 1 881 | 86,7% | manter |
| `Kurn` (raiz: `AppComposition`, `KurnApp`) | 299 | 88,6% | manter |

Faltam cerca de 2 400 linhas cobertas para chegar a 80%. `Services` sozinho
responde por ~3 800 das 6 800 linhas descobertas, por isso a Fase 3 é a maior.
A medição anterior registrada aqui (04/09, 46,9%) usava outro denominador,
com as Views dentro, e não é comparável.

Até a Fase 0, o relatório do KurnCore nunca chegava ao Codecov: o export
avisava, saía com 0 e deixava o job verde.

## Fases (cada uma pode ter vários PRs, e cada PR sobe o piso)

### Fase 0: medir e ligar o gate ✅ (este PR)

- Export do KurnCore consertado. Agora ele falha alto e publica o lcov como artifact.
- `Tools/lcov.py` (leitura e escopo compartilhados), `Tools/coverage_gate.py`,
  `Tools/coverage_scope.json`, `Tools/coverage_floor.json`, com testes em
  `Tools/tests/` rodando no `static-policy`.
- Job `coverage-gate` (precisa de `unit-tests`, `ui-accessibility-tests` e
  `kurncore-linux`). O `release`, o `beta` e o `store-assets` dependem dele.
- Passo manual do mantenedor: marcar `coverage-gate` como check obrigatório
  na branch protection de `main`.
- Piso inicial registrado com os valores medidos acima.

### Fase 1: KurnCore ≥ 85% (1 PR)

É o ganho mais barato: Foundation pura, `swift test` no Linux e iteração local
sem esperar o macOS. O alvo é o que o relatório `kurncore` apontar como
descoberto (`SpokenText`, `PCMWaveFile`, `ReliabilityEvent`, os tipos de
valor do pipeline e os seams de filesystem/relógio).

### Fase 2: extrair a lógica dos adapters e excluir os cascos (2–3 PRs)

Para cada arquivo preso a framework, primeiro mover as decisões para um tipo
puro testado em `KurnTests` e só depois listar o casco em `exclude`:

- `Services/Pipeline/WhisperCppTranscriber.swift`: agregação de peças
  SentencePiece em palavras, montagem de params, `t0/t1` → spans.
- `Services/OnDeviceTranscriber.swift`: validação de timings contra o range do
  resultado e run → `TimedWordSpanBuilder`.
- `FluidAudioDiarizer`, `FluidAudioTranscriber`, `FluidAudioVAD`,
  `FluidAudioModelStore`, `FluidAudioMultilingualStreamingManager`,
  `SherpaOnnxDiarizer`: `processTimeout` e montagem de config. O
  pós-processamento já está em `SpeakerTurnSmoothing`, `SpeakerClusterRefiner`
  e `SpeakerVoiceprints`.
- `LockScreenRecordingController` (State → `ContentState`),
  `PhoneSessionController` (codec do contexto e das mensagens),
  `RecordingAccessGate` (política de relock), `Speech/SystemSpeechEngine` e
  `Speech/CloudSpeechEngine` (fila e prefetch),
  `CrashReporting/DiagnosticsSubscriber`.
- Implementação real de `AudioCaptureEngine` e `CaptureAudioSession`: a
  decisão já está em `CaptureInputSelection`.
- Tipos de apresentação puros que hoje moram em `Views/`
  (`MarkdownPresentation`, …) descem para junto do tipo que apresentam, para
  voltar a contar.

### Fase 3: Services ≥ 80% (3–4 PRs, o maior bloco)

Usa os seams e fakes que já existem: `PipelineEngineCatalog`, `AudioCaptureEngine`,
`KurnTests/Support/FaultInjection` (`FakeFileSystem`, `FakeAudioSinkWriting`),
`AudioFixtures` e `MockURLProtocol`.

- `TranscriptionService` com `+Gating`, `+Diarization` e
  `TranscriptionServiceInputPreparation`: cada fallback de
  `effectiveDiarization`/`effectiveCorrection`, remap da compactação com
  `speakerTurns`, escolha de chunk boundary, preprocess falhando → original.
- `AudioRecorderService` e `RecordingSink`: matriz de interrupção, rota,
  reconfiguração e falha de escrita pelo fake engine.
- DSP com fixtures reais (o render offline roda no simulador):
  `SpeakerDiarizer`, `EnergyVAD`, `DiarizationPreprocessor`, `AudioPreprocessor`,
  `AudioChunker`, `RecordingCompactor`, `OfflineAudioRenderer` e `Enhancement/*`
  (sem modelo → caminho DSP).
- LLM com fake `LLMProvider`/`SpeechSynthesisProvider`: `SummaryService`,
  `WikiService`, `DocumentGenerationService`, `AutoTaggingService`,
  `MeetingChatService`, `Speech/ReadAloudController`.
- `LiveTranscriptionService`: gate de in-flight e engine por idioma.

### Fase 4: Application + ViewModels ≥ 80% (2 PRs)

Testes `@MainActor` de máquina de estados sobre `TestModelContainer.make()`:

- `TranscriptionCoordinator` (+`Speakers`: matching total, ordem por
  `recordedAt`, próximo label livre), `WikiCoordinator`,
  `SemanticIndexCoordinator` (backfill), `AITitleCoordinator`,
  `MeetingLibrary`, `AppComposition`.
- `RecorderViewModel`, `SummaryViewModel`, `MeetingChatViewModel`,
  `DocumentGenerationViewModel`, `ModelDownloadController`,
  `RecordingCompactionViewModel`.

### Fase 5: Infrastructure, Providers e Models ≥ 85%, e fechar em 80%

- `TranscriptionScheduler`, `RecordingRecovery`, `ModelDownloadConsent` e o
  boot/salvage restante (em `KurnSwiftDataTests` quando precisar de isolamento
  de processo).
- Quando o total em escopo passar de 80%, o piso registrado fica ≥ 80%. A
  partir daí a meta vira o mínimo, e a catraca só sobe.

## Riscos

- Mexer em `TranscriptionService` e `AudioRecorderService` exige rodar o lane
  TSan (`reliability-hardening.yml`) antes do merge, num PR para cada seam.
- A cobertura dos UI tests entra na união. Se um fluxo for desligado (skip por
  flake), o total pode cair um pouco: a tolerância de 0,5pp absorve ruído, mas
  não uma suíte inteira. Nesse caso, o PR que desliga a suíte explica a queda e
  regrava o piso, e essa é a única exceção à regra de nunca baixar o piso.
- Excluir arquivos é a forma mais fácil de "subir" o número. Por isso cada
  exclusão traz a justificativa e é revisada como código.
