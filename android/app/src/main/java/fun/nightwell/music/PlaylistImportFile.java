package fun.nightwell.music;

import java.io.*;
import java.nio.*;
import java.nio.charset.*;

/** Bounded text decoding shared by all document providers; never assumes a file path. */
final class PlaylistImportFile {
    static final int LIMIT = 1024 * 1024;
    static String read(InputStream input) throws IOException {
        if (input == null) throw new IOException("Не удалось открыть файл");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int count;
        while ((count = input.read(chunk)) != -1) {
            if (output.size() + count > LIMIT) throw new IOException("Максимальный размер файла — 1 МБ");
            output.write(chunk, 0, count);
        }
        byte[] bytes = output.toByteArray();
        Charset charset = StandardCharsets.UTF_8;
        int offset = 0;
        if (bytes.length >= 3 && (bytes[0]&255)==239 && (bytes[1]&255)==187 && (bytes[2]&255)==191) offset=3;
        else if (bytes.length >= 2 && (bytes[0]&255)==255 && (bytes[1]&255)==254) { charset=StandardCharsets.UTF_16LE; offset=2; }
        else if (bytes.length >= 2 && (bytes[0]&255)==254 && (bytes[1]&255)==255) { charset=StandardCharsets.UTF_16BE; offset=2; }
        final String text;
        try {
            text = charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, offset, bytes.length-offset)).toString();
        } catch (CharacterCodingException error) { throw new IOException("Сохрани список в UTF-8 или UTF-16 и выбери файл снова"); }
        if (text.trim().isEmpty()) throw new IOException("В выбранном файле нет треков");
        for (int i=0; i<text.length(); i++) {
            char c=text.charAt(i);
            if (c<32 && c!='\n' && c!='\r' && c!='\t') throw new IOException("Выбери текстовый файл JSON, CSV или TXT");
        }
        if (text.getBytes(StandardCharsets.UTF_8).length > LIMIT) throw new IOException("Список после чтения превышает 1 МБ");
        return text;
    }
}
