# Kurn — Plano para melhorar a cobertura de testes

Base: lcov reais do CI em `main` (04/09/2026, após o merge do #186).
`unittests` + `uitests` combinados: **46,9 %** das 26 545 linhas executáveis de
primeira parte (unit sozinho: 39,7 %). `kurncore` (Linux): 46,2 %.

## 1. Onde a cobertura está (e onde não está)

| Camada | Linhas | Combinado | Só unit | Não cobertas |
|---|---:|---:|---:|---:|
| `Kurn/Views` | 8 449 | 23,4 % | 7,2 % | **6 469** |
| `Kurn/Services` | 9 188 | 50,8 % | 49,9 % | **4 516** |
| `Kurn/ViewModels` | 2 400 | 32,2 % | 29,1 % | **1 626** |
| `Kurn/Infrastructure` | 3 306 | 80,9 % | 80,5 % | 631 |
| `KurnWatch` | 240 | 0 % | 0 % | 240 |
| `KurnLiveActivityExtension` | 228 | 0 % | 0 % | 228 |
| `Kurn/Models` | 852 | 82,6 % | 82,5 % | 148 |
| `Kurn/Providers` | 1 184 | 88,5 % | 88,5 % | 136 |
| `Kurn/AppIntents` | 60 | 0 % | 0 % | 60 |
| `Kurn/DebugSupport` | 362 | 97,5 % | 0 % | 9 |

Leitura: o trilho de resiliência (Infrastructure/Providers/Models) está bem
coberto. O gap está em três lugares — **Views** (54 % de todas as linhas não
cobertas), **Services de áudio/pipeline** que dependem de hardware ou de
modelos, e **ViewModels grandes** com muitas dependências concretas.

### Top 15 arquivos por linhas não cobertas

| Arquivo | Linhas | Cob. | Não cob. | Por quê |
|---|---:|---:|---:|---|
| `Services/TranscriptionService.swift` | 616 | 7,5 % | 570 | Orquestra 16 engines concretos criados no `init`; só testado via harness (skip em CI) |
| `Services/AudioRecorderService.swift` | 630 | 20,3 % | 502 | `AVAudioEngine`/sessão de áudio real; só a parte de storage/stall é testada |
| `ViewModels/TranscriptionViewModel.swift` | 633 | 36,3 % | 403 | Só o caminho de atribuição de erro tem teste |
| `Views/SettingsProviderViews.swift` | 457 | 15,1 % | 388 | UI test não navega para Providers |
| `Views/MeetingDetailView.swift` | 736 | 51,6 % | 356 | Só o audit de acessibilidade passa por aqui |
| `Services/Pipeline/WhisperCppTranscriber.swift` | 322 | 0,3 % | 321 | Requer modelo ggml baixado |
| `Views/Settings/StorageSettingsView.swift` | 309 | 2,6 % | 301 | Não navegada |
| `Views/Settings/TranscriptionSettingsView.swift` | 292 | 0 % | 292 | Não navegada |
| `Views/MeetingChatView.swift` | 269 | 0 % | 269 | Não navegada |
| `Views/FolderSidebarView.swift` | 265 | 0 % | 265 | iPad-only |
| `ViewModels/ModelDownloadController.swift` | 277 | 8,3 % | 254 | Máquina de estados de confirmação/download sem teste |
| `Views/MeetingShareSelectionView.swift` | 253 | 0 % | 253 | Não navegada |
| `Views/TagManagementView.swift` | 231 | 0 % | 231 | Não navegada |
| `Views/DocumentCreateView.swift` | 230 | 0 % | 230 | Não navegada |
| `ViewModels/RecorderViewModel.swift` | 392 | 44,6 % | 217 | Caminhos de erro/interrupção sem teste |

Outros com 0–10 % e alto valor: `Infrastructure/TranscriptionScheduler.swift`
(123 linhas, 2,4 % — é infra pura, o único buraco relevante da camada),
`Services/LiveTranscriptionService.swift` (5,8 %),
`Services/Pipeline/TranscriptionServiceInputPreparation.swift` (0 %),
`ViewModels/TranscriptionViewModel+Summary.swift` (0 %),
`Services/AudioPlayerService.swift` (12 %), `Services/FluidAudioDiarizer.swift`
(5,3 %, modelo), `Services/OnDeviceTranscriber.swift` (12,6 %, Apple Speech).

## 2. Princípios

1. **Medir o que importa, não perseguir o número.** Meta por camada, não meta
   global: um `README` com 70 % obtido cobrindo `Views` com snapshots vale
   menos do que 80 % em `Services`.
2. **Sem testes que dependem de rede, modelo baixado ou microfone em CI.** O
   projeto já tem a resposta certa (`EvaluationHarnessTests` só roda com
   `KURN_EVAL_DATA`); código que exige modelo fica atrás de um protocolo e o
   protocolo é testado com fake.
3. **Seams antes de testes.** Nos três arquivos maiores, o motivo da baixa
   cobertura é estrutural (dependências concretas no `init`). Primeiro
   injetar, depois testar — nunca `#if DEBUG` dentro da lógica.
4. **Cobertura do trilho H1–H10 não pode cair.** Adicionar ao `codecov.yml`
   um flag/`target` informativo por diretório (`Infrastructure/`,
   `Providers/`) para que uma queda apareça no comentário do PR.
5. Não alterar testes para "passar"; testes flaky por estado global (como os
   dois corrigidos no #186) são bugs de isolamento e entram no plano.

## 3. Fases (cada fase = 1 PR revisável; estimativa em sessões Devin)

### Fase 0 — Tornar a cobertura acionável (½ sessão)

- `codecov.yml`: `flags` por camada (`services`, `viewmodels`, `views`,
  `infrastructure`) além dos três atuais; `comment.layout` com `flags`;
  `ignore` para `KurnWatch/`, `KurnLiveActivityExtension/` **até** existir um
  job que os exercite (hoje distorcem o total para baixo sem chance de subir).
- `Tools/coverage_report.py`: lê o(s) lcov do artifact e imprime a tabela da
  seção 1 (por camada + top-N arquivos). Roda no job summary de `unit-tests`
  para que cada PR mostre para onde a cobertura foi.
- Ganho direto: 0 pontos; torna as fases seguintes mensuráveis.

### Fase 1 — Vitórias baratas em Infrastructure/Services puros (1 sessão)

Alvo: `Services` 50,8 % → ~58 %, `Infrastructure` 80,9 % → ~90 %.

- `TranscriptionScheduler` (2,4 %): já tem `register(containerProvider:)`;
  testar `scheduleIfWorkRemains`, `run(container:)` com container em memória
  (padrão de `KurnSwiftDataTests`), `pause()`, e o caminho "sem trabalho".
- `TranscriptionServiceInputPreparation` (0 %): funções sobre `URL`/arquivo —
  usar `AudioFixtures` (já existe) para formatos válidos/inválidos.
- `VADAudioCompactor` (32,7 %): ramos de "nenhum trecho de voz", "tudo voz",
  segmentos adjacentes fundidos; `RecordingCompactor` (20,3 %): falha de
  verificação, falha no swap atômico, cancelamento — usar
  `FakeFileSystem`/`FakeAudioSinkWriting` já em `Support/FaultInjection`.
- `RecordingSink` (44,5 %): ramos de erro do writer, disco cheio, interrupção
  — `RecordingSinkFaultTests` já tem a estrutura; ampliar matriz.
- `DocumentGenerationService` (31 %): caminho feliz com `LLMProvider` fake e
  respostas malformadas (parsing), reaproveitando `MockURLProtocol`.
- `LiveTranscriptionService` (5,8 %): separar a parte de buffer/janela (pura)
  da parte `SFSpeechRecognizer` e testar a primeira.

### Fase 2 — Seams nos três grandes (1–2 sessões)

Alvo: `TranscriptionService` 7,5 % → ≥ 60 %; `AudioRecorderService`
20 % → ≥ 55 %; `ViewModels` 32 % → ≥ 55 %.

- **`TranscriptionService`** (feito — `Kurn/Services/Pipeline/PipelineEngineCatalog.swift`,
  `KurnTests/TranscriptionServicePipelineTests.swift`): mover a criação dos 16 engines para um
  `PipelineEngineCatalog` (struct com closures/protocolos por estágio,
  `Sendable`) recebido no `init` com default = engines reais. O
  `transcribe(...)` passa a ser testável de ponta a ponta com fakes por
  estágio: checkpoint retomado/descartado, `onPhase` em ordem, chunk loop,
  `onDiarizationWarning`, cancelamento entre chunks, falha em um estágio
  preservando o `PipelineStageReport`. Também destrava o refactor de tamanho
  já apontado na revisão (600+ linhas).
- **`AudioRecorderService`** (feito — `Kurn/Services/AudioCaptureEngine.swift`,
  `KurnTests/AudioRecorderServiceCaptureTests.swift`): separar o núcleo de
  estado (start/pause/resume/markHighlight/stop/cancel, storage, stall) de um
  `AudioCaptureEngine` protocol que embrulha `AVAudioEngine`/`AVAudioSession`.
  O fake dispara interrupções, mudança de rota, mudança de configuração/reset
  de media services, formato não negociado e erros do sink — os cenários que
  antes só o TSan lane exercitava indiretamente.
- **`TranscriptionViewModel` / `+Summary` / `RecorderViewModel` /
  `ModelDownloadController`**: já recebem dependências no `init`; escrever
  testes de máquina de estados com fakes (`@MainActor` tests, sem UI):
  transições de confirmação (batch ASR / diarization / VAD / whisper.cpp:
  confirmar, cancelar, rede cara vs Wi-Fi via `LargeTransferPolicy`),
  `deleteModel`, `refreshInstalledModels`; no `RecorderViewModel`, cada
  `PauseReason`, stop com resultado nulo, launcher externo vs UI.
- **`AudioPlayerService`**: extrair a lógica de rate/seek/skip/clamp para um
  tipo puro; o `AVAudioPlayer` fica por trás de um protocolo.

### Fase 3 — Views com valor (1 sessão)

Alvo: `Views` 23 % → ~40 % sem snapshots frágeis.

- Extrair lógica de apresentação embutida nas Views para tipos puros
  testáveis em `KurnTests` (padrão que `MeetingExport`/`MeetingFilter` já
  seguem): formatação de `HealthRecoveryView+Sections` (agregação dos
  estados de recovery), `FilterBarView` (composição de filtros),
  `MarkdownText` (parser), `SegmentPlaybackScrubber` (mapeamento
  tempo↔posição), `MeetingShareSelectionView` (seleção → `MeetingExport`).
- Estender `KurnUITests` com **fluxos**, não só audit: Settings → Providers
  (Foundation Models default, chave ausente), Settings → Transcription
  (troca de engine sem download), Settings → Storage/Health & Recovery,
  Tags e Folders CRUD, Share sheet até a seleção de formato Obsidian, Chat
  (com provider indisponível → estado vazio). Cada fluxo com
  `accessibilityIdentifier`s estáveis; medir o flake rate no lane
  `reliability-hardening` antes de promover para o job obrigatório.
- Não fazer: snapshot testing pixel-a-pixel (Liquid Glass/iOS 26 muda por
  release; custo de manutenção alto, sinal baixo).
- Entregue: `HealthRecoveryAggregation`, `PlaybackScrubberLayout`,
  `MarkdownPresentation`, `MeetingShareSelection`/`MeetingShareFormat` e
  `MeetingFilter.toggleTag/toggleStatus` (KurnCore), com suítes em
  `KurnTests`; fluxos em `KurnUITests/Flows/` (`SettingsFlowUITests`,
  `LibraryFlowUITests`, `ShareAndChatFlowUITests`). Medição no lane
  `ui-flake-rate`: 5/5 tentativas verdes em `main`; os fluxos foram
  promovidos ao job obrigatório `ui-accessibility-tests` (remoção das linhas
  `-skip-testing` em `swift.yml`). Suíte que passar a oscilar volta para trás
  de um skip até ser corrigida e re-medida.

### Fase 4 — Targets hoje em 0 % (1 sessão, opcional)

- `KurnWatch` / `KurnLiveActivityExtension` / `AppIntents`: o código de UI
  não roda no simulador iOS. Estratégia: mover a lógica compartilhável
  (`WatchConnectivityManager` message codec, estado da Live Activity,
  `StartRecordingIntent` → `RecordingLauncher`) para `KurnCore` ou para
  tipos puros no target `Kurn`, cobertos em `KurnTests`/Linux. Um job
  `watch-tests` (`KurnWatchUITests` no simulador watchOS) só se o flake rate
  for aceitável — hoje é o mesmo follow-up já registrado na revisão.
- Depois disso, remover o `ignore` da Fase 0.

## 4. Metas propostas (informativas, como o `codecov.yml` já é)

| | Hoje | Após F1 | Após F2 | Após F3 |
|---|---:|---:|---:|---:|
| Total (unit+ui) | 46,9 % | ~52 % | ~62 % | ~68 % |
| `Services` | 50,8 % | ~58 % | ~72 % | ~72 % |
| `ViewModels` | 32,2 % | 32 % | ~58 % | ~60 % |
| `Infrastructure` | 80,9 % | ~90 % | ~90 % | ~90 % |
| `Views` | 23,4 % | 23 % | 25 % | ~40 % |

Números derivados das linhas não cobertas por arquivo acima; são metas de
planejamento, não SLO (mesma regra do H10: nada de gate numérico sem
baseline).

## 5. Riscos e decisões

- Fase 2 toca `TranscriptionService` e `AudioRecorderService`, os dois
  arquivos mais sensíveis do app; cada seam vai em PR próprio com o lane TSan
  rodado antes do merge.
- UI tests novos aumentam o tempo do job `ui-accessibility-tests`
  (hoje ~15 min). Se passar de ~25 min, separar em job próprio.
- Cobertura de `uitests` (15,7 %) e `unittests` (40 %) é somada pelo Codecov
  no total; manter os flags separados como já está para não mascarar.
- Decisão necessária: ordem F1→F2→F3 (recomendada: destrava refactor de
  tamanho e cobre o pipeline crítico primeiro) ou F3 primeiro se a prioridade
  for regressão visual das telas novas (Health & Recovery, Providers).
