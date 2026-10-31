package com.aquan.duanju.mirror

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32

/**
 * MPEG-TS 封装器（移植自 DlnaCast TsMuxer.kt，包名适配 + 去逐帧日志）。
 *
 * 将 H.264（NAL Unit）与 AAC 封装为 MPEG-TS：DLNA Renderer 通常不认裸 H.264，
 * 需要标准容器；MPEG-TS 是直播场景最通用的容器。
 *
 * PID：0x0000 PAT / 0x0010 PMT / 0x0100 视频(H264, stream_type 0x1B) /
 * 0x0101 音频(AAC, stream_type 0x0F)。PAT/PMT 每 500ms 重发，PCR 挂在视频首包。
 */
class MirrorTsMuxer {

    companion object {
        const val TS_PACKET_SIZE = 188
        private const val SYNC_BYTE: Byte = 0x47
        private const val PID_PAT = 0x0000
        private const val PID_PMT = 0x0010
        private const val PID_VIDEO = 0x0100
        private const val PID_AUDIO = 0x0101
        private const val STREAM_TYPE_H264 = 0x1B
        private const val STREAM_TYPE_AAC = 0x0F
        private const val TS_PAYLOAD_UNIT_START = 0x40
        private const val TS_ADAPTATION_PAYLOAD = 0x30
        private const val CONTINUITY_MASK = 0x0F
        private const val PAT_PMT_INTERVAL_MS = 500L
    }

    private var continuityVideo = 0
    private var continuityAudio = 0
    private var continuityPat = 0
    private var continuityPmt = 0
    private var lastPatPmtTime = 0L
    private var lastPcrWallMs = 0L
    private val programNumber = 1

    /** 保证多线程（视频/音频编码线程）互斥写 */
    private val lock = Any()

    fun writeVideo(data: ByteArray, isKeyFrame: Boolean, pts: Long): ByteArray = synchronized(lock) {
        val output = ByteArrayOutputStream()
        if (shouldSendPatPmt()) {
            output.write(generatePAT())
            output.write(generatePMT())
        }
        // PCR 每 ≥500ms 插入一次视频首包（直播流时钟恢复必需）。
        val nowMs = System.currentTimeMillis()
        val insertPcr = lastPcrWallMs == 0L || nowMs - lastPcrWallMs >= PAT_PMT_INTERVAL_MS
        val pesPacket = createPesPacket(data, isKeyFrame, pts, pts)
        val tsPackets = splitIntoTsPackets(
            pesPacket, PID_VIDEO, continuityVideo, true,
            insertPcr, pts * 90L / 1000000L,
        )
        if (insertPcr) lastPcrWallMs = nowMs
        output.write(tsPackets)
        val packetCount = tsPackets.size / TS_PACKET_SIZE
        continuityVideo = (continuityVideo + packetCount) and CONTINUITY_MASK
        output.toByteArray()
    }

    fun writeAudio(data: ByteArray, pts: Long): ByteArray = synchronized(lock) {
        val output = ByteArrayOutputStream()
        val pesPacket = createAacPesPacket(data, pts)
        val tsPackets = splitIntoTsPackets(pesPacket, PID_AUDIO, continuityAudio, true)
        output.write(tsPackets)
        val packetCount = tsPackets.size / TS_PACKET_SIZE
        continuityAudio = (continuityAudio + packetCount) and CONTINUITY_MASK
        output.toByteArray()
    }

    /** 初始 PAT+PMT（电视/VLC 打开流时首先需要） */
    fun getInitialPackets(): ByteArray = synchronized(lock) {
        val output = ByteArrayOutputStream()
        output.write(generatePAT())
        output.write(generatePMT())
        output.toByteArray()
    }

    private fun shouldSendPatPmt(): Boolean {
        val now = System.currentTimeMillis()
        if (lastPatPmtTime == 0L || now - lastPatPmtTime >= PAT_PMT_INTERVAL_MS) {
            lastPatPmtTime = now
            return true
        }
        return false
    }

    private fun generatePAT(): ByteArray {
        val pat = ByteArrayOutputStream()
        pat.write(0x00) // table_id
        pat.write(0xB0) // section_syntax_indicator + reserved
        val sectionLengthPos = pat.size()
        pat.write(0x00)
        pat.write(0x00)
        pat.write(0x00)
        pat.write(0x01) // transport_stream_id
        pat.write(0xC1) // reserved + version + current_next
        pat.write(0x00) // section_number
        pat.write(0x00) // last_section_number
        pat.write((programNumber shr 8) and 0xFF)
        pat.write(programNumber and 0xFF)
        pat.write(0xE0 or ((PID_PMT shr 8) and 0x1F))
        pat.write(PID_PMT and 0xFF)
        val payload = finishSection(pat, sectionLengthPos)
        return wrapSingleTsPacket(payload, PID_PAT, continuityPat, true).also {
            continuityPat = (continuityPat + 1) and CONTINUITY_MASK
        }
    }

    private fun generatePMT(): ByteArray {
        val pmt = ByteArrayOutputStream()
        pmt.write(0x02) // table_id
        pmt.write(0xB0)
        val sectionLengthPos = pmt.size()
        pmt.write(0x00)
        pmt.write(0x00)
        pmt.write((programNumber shr 8) and 0xFF)
        pmt.write(programNumber and 0xFF)
        pmt.write(0xC1)
        pmt.write(0x00)
        pmt.write(0x00)
        pmt.write(0xE0 or ((PID_VIDEO shr 8) and 0x1F)) // PCR_PID = 视频
        pmt.write(PID_VIDEO and 0xFF)
        pmt.write(0xF0) // program_info_length = 0
        pmt.write(0x00)
        // 视频流
        pmt.write(STREAM_TYPE_H264)
        pmt.write(0xE0 or ((PID_VIDEO shr 8) and 0x1F))
        pmt.write(PID_VIDEO and 0xFF)
        pmt.write(0xF0)
        pmt.write(0x00)
        // 音频流
        pmt.write(STREAM_TYPE_AAC)
        pmt.write(0xE0 or ((PID_AUDIO shr 8) and 0x1F))
        pmt.write(PID_AUDIO and 0xFF)
        pmt.write(0xF0)
        pmt.write(0x00)
        val payload = finishSection(pmt, sectionLengthPos)
        return wrapSingleTsPacket(payload, PID_PMT, continuityPmt, true).also {
            continuityPmt = (continuityPmt + 1) and CONTINUITY_MASK
        }
    }

    /** 补 section_length + CRC32，返回完整 section 字节 */
    private fun finishSection(out: ByteArrayOutputStream, sectionLengthPos: Int): ByteArray {
        val beforeCrc = out.toByteArray()
        val crc = CRC32().apply { update(beforeCrc) }.value.toInt()
        out.write((crc shr 24) and 0xFF)
        out.write((crc shr 16) and 0xFF)
        out.write((crc shr 8) and 0xFF)
        out.write(crc and 0xFF)
        val payload = out.toByteArray()
        val sectionLength = payload.size - 3 - 4 // 头 3 字节 + CRC 4 字节
        payload[sectionLengthPos] = ((sectionLength shr 8) and 0x0F).toByte()
        payload[sectionLengthPos + 1] = (sectionLength and 0xFF).toByte()
        return payload
    }

    private fun createPesPacket(data: ByteArray, isKeyFrame: Boolean, pts: Long, dts: Long): ByteArray {
        val pes = ByteArrayOutputStream()
        pes.write(0x00)
        pes.write(0x00)
        pes.write(0x01)
        pes.write(0xE0) // stream_id 视频
        val ptsDtsLength = if (dts != pts) 10 else 5
        val pesPacketLength = 3 + ptsDtsLength + data.size
        if (pesPacketLength > 0xFFFF) {
            pes.write(0x00)
            pes.write(0x00)
        } else {
            pes.write((pesPacketLength shr 8) and 0xFF)
            pes.write(pesPacketLength and 0xFF)
        }
        pes.write(0x80) // '10' + flags
        val ptsDtsIndicator = if (dts != pts) 0x03 else 0x02
        pes.write(ptsDtsIndicator shl 6)
        pes.write(ptsDtsLength)
        writePts(pes, pts)
        if (ptsDtsIndicator == 0x03) writePts(pes, dts)
        pes.write(data)
        return pes.toByteArray()
    }

    private fun createAacPesPacket(data: ByteArray, pts: Long): ByteArray {
        val pes = ByteArrayOutputStream()
        pes.write(0x00)
        pes.write(0x00)
        pes.write(0x01)
        pes.write(0xC0) // stream_id 音频
        val pesPacketLength = 3 + 5 + data.size
        if (pesPacketLength > 0xFFFF) {
            pes.write(0x00)
            pes.write(0x00)
        } else {
            pes.write((pesPacketLength shr 8) and 0xFF)
            pes.write(pesPacketLength and 0xFF)
        }
        pes.write(0x80)
        pes.write(0x80) // PTS_DTS_flags = '10'（仅 PTS）
        pes.write(0x05)
        writePts(pes, pts)
        pes.write(data)
        return pes.toByteArray()
    }

    /** PES → 188 字节 TS 包序列（首包 PUSI；末包/短包 adaptation field 填充；视频首包可插 PCR） */
    private fun splitIntoTsPackets(
        pesData: ByteArray,
        pid: Int,
        continuityCounter: Int,
        payloadUnitStart: Boolean,
        insertPcr: Boolean = false,
        pcrBase: Long = 0L,
    ): ByteArray {
        val output = ByteArrayOutputStream()
        var offset = 0
        var cc = continuityCounter
        val headerSize = 4

        while (offset < pesData.size) {
            val isFirst = (offset == 0) && payloadUnitStart
            val remaining = pesData.size - offset
            val packet = ByteArray(TS_PACKET_SIZE)
            packet[0] = SYNC_BYTE
            packet[1] = (((pid shr 8) and 0x1F) or if (isFirst) TS_PAYLOAD_UNIT_START else 0x00).toByte()
            packet[2] = (pid and 0xFF).toByte()

            if (isFirst && insertPcr) {
                // PCR adaptation field：header(4)+len(1)+flags(1)+PCR(6)+stuffing+payload
                val maxPayloadWithPcr = TS_PACKET_SIZE - headerSize - 1 - 7 // = 176
                val stuffingLen = if (remaining < maxPayloadWithPcr) maxPayloadWithPcr - remaining else 0
                val adaptFieldLen = 7 + stuffingLen
                packet[3] = (TS_ADAPTATION_PAYLOAD.toInt() or (cc and CONTINUITY_MASK)).toByte()
                packet[4] = adaptFieldLen.toByte()
                packet[5] = 0x10 // flags: PCR_flag
                writePcrBytes(packet, 6, pcrBase)
                for (i in 0 until stuffingLen) {
                    packet[12 + i] = 0xFF.toByte()
                }
                val payloadOffset = headerSize + 1 + adaptFieldLen
                val payloadSize = minOf(remaining, TS_PACKET_SIZE - payloadOffset)
                System.arraycopy(pesData, offset, packet, payloadOffset, payloadSize)
                for (i in (payloadOffset + payloadSize) until TS_PACKET_SIZE) {
                    packet[i] = 0xFF.toByte()
                }
                output.write(packet)
                offset += payloadSize
            } else {
                val maxPayload = TS_PACKET_SIZE - headerSize // 184
                if (remaining < maxPayload - 2) {
                    // 末包/短包：adaptation field 纯填充（符合 MPEG-TS 标准）
                    val stuffingLen = maxPayload - 2 - remaining
                    val adaptFieldLen = 1 + stuffingLen
                    packet[3] = (TS_ADAPTATION_PAYLOAD.toInt() or (cc and CONTINUITY_MASK)).toByte()
                    packet[4] = adaptFieldLen.toByte()
                    packet[5] = 0x00
                    for (i in 1 until stuffingLen) {
                        packet[5 + i] = 0xFF.toByte()
                    }
                    val payloadOffset = headerSize + 1 + adaptFieldLen
                    System.arraycopy(pesData, offset, packet, payloadOffset, remaining)
                    for (i in (payloadOffset + remaining) until TS_PACKET_SIZE) {
                        packet[i] = 0xFF.toByte()
                    }
                    output.write(packet)
                    offset += remaining
                } else {
                    packet[3] = (cc and CONTINUITY_MASK).toByte()
                    val payloadSize = minOf(remaining, maxPayload)
                    System.arraycopy(pesData, offset, packet, headerSize, payloadSize)
                    for (i in (headerSize + payloadSize) until TS_PACKET_SIZE) {
                        packet[i] = 0xFF.toByte()
                    }
                    output.write(packet)
                    offset += payloadSize
                }
            }
            cc = (cc + 1) and CONTINUITY_MASK
        }
        return output.toByteArray()
    }

    /** PCR：42 位（33 位 base + 6 位 reserved + 9 位 ext=0），pcr_base = pts_90kHz */
    private fun writePcrBytes(packet: ByteArray, offset: Int, pcrBase: Long) {
        val base = pcrBase and 0x1FFFFFFFFL
        packet[offset] = ((base shr 25) and 0xFF).toByte()
        packet[offset + 1] = ((base shr 17) and 0xFF).toByte()
        packet[offset + 2] = ((base shr 9) and 0xFF).toByte()
        packet[offset + 3] = ((base shr 1) and 0xFF).toByte()
        packet[offset + 4] = (((base.toInt() and 1) shl 7) or 0x7E).toByte()
        packet[offset + 5] = 0x00
    }

    private fun wrapSingleTsPacket(
        payload: ByteArray,
        pid: Int,
        continuityCounter: Int,
        payloadUnitStart: Boolean,
    ): ByteArray {
        val packet = ByteArray(TS_PACKET_SIZE)
        val payloadSize = minOf(payload.size, TS_PACKET_SIZE - 4)
        packet[0] = SYNC_BYTE
        packet[1] = (((pid shr 8) and 0x1F) or if (payloadUnitStart) TS_PAYLOAD_UNIT_START else 0x00).toByte()
        packet[2] = (pid and 0xFF).toByte()
        packet[3] = (continuityCounter and CONTINUITY_MASK).toByte()
        System.arraycopy(payload, 0, packet, 4, payloadSize)
        for (i in (4 + payloadSize) until TS_PACKET_SIZE) {
            packet[i] = 0xFF.toByte()
        }
        return packet
    }

    private fun writePts(output: ByteArrayOutputStream, ptsUs: Long) {
        val pts33 = ptsUs * 90L / 1000000L // 微秒 → 90kHz
        val high = 0x30 or (((pts33 shr 29) and 0x0E).toInt()) or 0x01
        output.write(high)
        output.write(((pts33 shr 22) and 0xFF).toInt())
        output.write((((pts33 shr 14) and 0xFE).toInt()) or 0x01)
        output.write(((pts33 shr 7) and 0xFF).toInt())
        output.write((((pts33 shl 1) and 0xFE).toInt()) or 0x01)
    }
}
