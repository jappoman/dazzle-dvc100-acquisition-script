# VHS1 — fotogrammi temporali estranei

Data dell'analisi: 8 settembre 2026.

## Problema confermato

Nel master `dazzle-capture-2026-09-07_16-28-52 - VHS1.mkv` (VHS1, scuola
materna) compaiono brevi flash di immagini non appartenenti al momento corrente.
Un controllo visivo a piena risoluzione ha confermato un episodio a circa
**00:04:18,88**: per due fotogrammi compaiono gli adulti, immagini presenti
circa **0,48 secondi** prima, in mezzo a una sequenza continua dei bambini.

Una scansione dei primi trenta minuti ha trovato almeno 143 episodi distinti.
La distanza non è fissa ma è spesso vicina a mezzo secondo; il difetto potrebbe
proseguire anche oltre i primi trenta minuti.

Il log del master riporta inoltre:

```text
dup=6206 drop=1750
```

Questi contatori non dimostrano da soli l'origine del difetto, ma indicano che
FFmpeg ha dovuto compensare in modo importante i timestamp della cattura.

## Correzione applicata allo script

`capture-dazzle.ps1` ora usa per impostazione predefinita:

```text
-VideoFrameRateMode Passthrough
```

Questa modalità conserva i timestamp prodotti dal Dazzle e non chiede a FFmpeg
di creare o eliminare fotogrammi per imporre una frequenza costante. Il precedente
comportamento è ancora disponibile solo con `-VideoFrameRateMode Cfr`.

## Prova da eseguire in cantina

1. Collega il Dazzle direttamente a una porta USB del PC, senza hub, e chiudi
   programmi pesanti.
2. Riavvolgi VHS1 a poco prima di 00:04:19.
3. Acquisisci almeno due minuti con il comando seguente; interrompi con `Q`.

```powershell
.\capture-dazzle.ps1 `
  -TapeLabel 'VHS1-timing-test' `
  -ContentDescription 'Timing test near 00:04:19' `
  -SignalProfile VHS
```

4. Conserva il file MKV e il relativo `.log`. Nel log finale verifica la riga
   `Frame-rate mode: Passthrough; FFmpeg sync corrections: ...`.
5. Controlla visivamente il punto corrispondente: se il flash non ricompare, la
   nuova modalità è adatta per riacquisire VHS1. Se ricompare, il problema è a
   monte della correzione CFR (driver, USB o Dazzle) e va diagnosticato dalla
   nuova acquisizione e dal suo log.

## Limite del master già esistente

Non esiste un modo lossless per ricostruire il contenuto sostituito dai flash.
Si possono eliminare i fotogrammi errati soltanto ricodificando piccole porzioni
del video, ma il movimento originale mancante non può essere recuperato. La
soluzione preferibile è una riacquisizione pulita.
